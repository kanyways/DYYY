//
//  DYYYUtils.m - DYYY 插件的"工具箱"工具类
//
//  定位：本文件不包含任何界面，只提供被 DYYY.xm / DYYYManager.m 到处调用的
//  能力函数：网络与缓存、图片/动图处理、UI 与视图树操作、文件管理、颜色方案、
//  日志、线程安全与调试辅助。绝大多数方法是类方法(+)或全局 C 函数，
//  因为 tweak 代码没有明确的"对象"边界，类方法/全局函数最方便从任意钩子里
//  直接调用，无需先创建实例。
//
//  功能地图（按 #pragma mark 区块划分，Xcode 跳转栏可直接定位）：
//  1. 模型过滤（Public Model Filtering Utilities）：判断抖音模型/原始数据是否广告，
//     用于去广告功能（arrayByRemovingAdvertisements:）。
//  2. UI 工具（Public UI Utilities）：当前窗口/顶层控制器、按类名找控件、毛玻璃、
//     Toast、深浅色判断。
//  3. 文件管理（Public File Management）：目录大小、清空目录、统一缓存目录。
//  4. 媒体工具（Public Media Helper Methods）：识别文件格式（魔数）、动图时长、
//     GIF 生成/保存相册、WebP/HEIC 转 GIF、视频合并音频。
//  5. 颜色方案（Public Color Scheme Methods）：把 "#FF0000"、"rainbow"、
//     "random" 等字符串解析成 UIColor / CALayer。
//  6. 私有辅助（Private Helper Methods）：以上各区共用的内部函数。
//  7. 版本比较（Version Utilities）、调试工具（Debug Utilities）。
//  8. 外部 C 函数（External C Functions）：供 Logos 钩子等 C 风格代码直接调用。
//
//  阅读建议：新人先看"IP 属地"方法（processAndApplyIPLocationToLabel:）和
//  颜色方案入口（colorFromSchemeHexString:），这两个方法浓缩了本文件大多数模式：
//  运行时探测、两级缓存、回调回主队列、锁与原子操作。
//
#import "DYYYUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <unistd.h>
#import "AwemeHeaders.h"
#import "DYYYConstants.h"
#import "DYYYToast.h"

@class YYImageDecoder;
@class YYImageFrame;

@interface YYImageFrame : NSObject
@property(nonatomic, strong) UIImage *image;
@property(nonatomic) CGFloat duration;
@end

@interface YYImageDecoder : NSObject
@property(nonatomic, readonly) NSUInteger frameCount;
+ (instancetype)decoderWithData:(NSData *)data scale:(CGFloat)scale;
- (YYImageFrame *)frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay;
@end

// 两个静态常量说明：
// kLabelColorStateKey：作为"关联对象（associated object）"的键。objc_setAssociatedObject
//   可以把自定义状态"挂"到任意对象（这里是 UILabel）上；键必须是一个稳定唯一的地址，
//   所以用"它自己的地址"做键，保证全局不冲突。
// kDYYYUtilsDefaultFrameDelay：动图单帧默认时长 0.1 秒（10 帧/秒），
//   当某帧没有记录时长或时长非法时兜底使用。
static const void *kLabelColorStateKey = &kLabelColorStateKey;
static const NSTimeInterval kDYYYUtilsDefaultFrameDelay = 0.1f;

// ==== 设置读取缓存（性能） ====
// 热路径 hook（setFrame / setBackgroundColor / CALayer 家族等每帧被调用
// 几十万次）不能直接读 NSUserDefaults——每次都是消息发送 + 哈希查找。
// 这里只对"设置面板才写入、运行时几乎不变"的 key 做内存缓存；
// 失效时机有两个：NSUserDefaultsDidChangeNotification（跨进程同步），
// 以及 DYYYSettingsHelper.setUserDefaults（面板写入）显式清缓存。
static NSMutableDictionary<NSString *, id> *s_settingsCache = nil;
static BOOL s_settingsObserverScheduled = NO;

// ==== 日志区块 ====
// DYYYNSLog 是插件自己的日志函数：一条日志同时发给 os_log（macOS 的 Console.app
// 或 Xcode 里可见）、stderr（越狱环境下 ssh 进设备即可看到），
// 并异步追加写入临时目录下的 runtime.log。
// 这里有两个常见的线程安全模式值得记住：
// 1. dispatch_once：保证初始化代码在进程生命周期内只执行一次，且线程安全——
//    多个线程同时第一次调用也不会重复执行，适合惰性创建单例/队列。
// 2. 串行队列 + dispatch_async：写文件是磁盘 IO，不该阻塞调用线程（可能正跑在
//    主线程上）；所有日志丢进同一个串行队列，写入互不交错、顺序不乱。
// GeoNames 磁盘缓存上限清理：缓存按城市码一城一个 plist 且只增不删，
// 长期使用会积累无界文件。在写入后顺带调用：超过上限时按修改时间
// 删除最旧的，直到回到上限内。可在任意线程执行（纯文件操作）。
static const NSInteger kDYYYGeoNamesDiskCacheLimit = 200;
static void DYYYTrimGeoNamesDiskCache(void) {
    NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *geoNamesCacheDir = [cachesDir stringByAppendingPathComponent:@"DYYYGeoNamesCache"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:geoNamesCacheDir error:nil];
    if (files.count <= kDYYYGeoNamesDiskCacheLimit) {
        return;
    }
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in files) {
        NSString *path = [geoNamesCacheDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        [entries addObject:@{@"path" : path, @"date" : attrs[NSFileModificationDate] ?: [NSDate distantPast]}];
    }
    // 新的在前，只保留最新的 200 个
    [entries sortUsingComparator:^NSComparisonResult(id a, id b) {
      return [b[@"date"] compare:a[@"date"]];
    }];
    for (NSInteger i = kDYYYGeoNamesDiskCacheLimit; i < (NSInteger)entries.count; i++) {
        [[NSFileManager defaultManager] removeItemAtPath:entries[i][@"path"] error:nil];
    }
}

static NSString *DYYYRuntimeLogFilePath(void) {
    static NSString *logPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      NSString *logsDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYYYLogs"];
      [[NSFileManager defaultManager] createDirectoryAtPath:logsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
      logPath = [logsDirectory stringByAppendingPathComponent:@"runtime.log"];
    });
    return logPath;
}

void DYYYNSLog(NSString *format, ...) {
    if (format.length == 0) {
        return;
    }

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (message.length == 0) {
        return;
    }

    static os_log_t dyyyLogger = nil;
    static dispatch_once_t loggerOnceToken;
    dispatch_once(&loggerOnceToken, ^{
      dyyyLogger = os_log_create("com.dyyy.tweak", "runtime");
    });
    os_log_with_type(dyyyLogger, OS_LOG_TYPE_DEFAULT, "%{public}@", message);

    const char *stderrMessage = message.UTF8String;
    if (stderrMessage) {
        fprintf(stderr, "%s\n", stderrMessage);
        fflush(stderr);
    }

    static dispatch_queue_t logQueue = nil;
    static dispatch_once_t queueOnceToken;
    dispatch_once(&queueOnceToken, ^{
      logQueue = dispatch_queue_create("com.dyyy.runtime-log.queue", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
      @autoreleasepool {
          NSString *line = [NSString stringWithFormat:@"[%@][pid:%d] %@\n", [NSDate date], getpid(), message];
          NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
          if (lineData.length == 0) {
              return;
          }

          NSString *logPath = DYYYRuntimeLogFilePath();
          NSFileManager *fileManager = [NSFileManager defaultManager];
          if (![fileManager fileExistsAtPath:logPath]) {
              [fileManager createFileAtPath:logPath contents:nil attributes:nil];
          }

          NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
          if (!fileHandle) {
              return;
          }
          @try {
              [fileHandle seekToEndOfFile];
              [fileHandle writeData:lineData];
          } @catch (NSException *exception) {
          }
          [fileHandle closeFile];
      }
    });
}

// 动图帧时长归一化：某些帧的时长可能是 NaN、无穷大或小于 0.01 秒（非法值），
// 直接写进 GIF 会让播放器行为异常（闪帧/卡死），这里统一兜底为默认 0.1 秒。
static inline CGFloat DYYYUtilsNormalizedDelay(CGFloat delay) {
    if (!isfinite(delay) || delay < 0.01f) {
        return kDYYYUtilsDefaultFrameDelay;
    }
    return delay;
}

@interface DYYYLabelColorState : NSObject
@property(nonatomic, copy) NSString *textSignature;
@property(nonatomic, copy) NSString *colorKey;
@property(nonatomic, copy) NSString *fontName;
@property(nonatomic, assign) CGFloat fontSize;
@end

@implementation DYYYLabelColorState
@end

static inline BOOL DYYYStringsEqual(NSString *lhs, NSString *rhs) {
    if (lhs == rhs) {
        return YES;
    }
    return [lhs isEqualToString:rhs];
}

static NSString *DYYYNormalizedColorKey(NSString *colorHexString) {
    if (colorHexString.length == 0) {
        return nil;
    }
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *trimmed = [colorHexString stringByTrimmingCharactersInSet:whitespace];
    if (trimmed.length == 0) {
        return nil;
    }
    return trimmed.lowercaseString;
}

static BOOL DYYYColorKeyIsDynamic(NSString *normalizedKey) {
    if (normalizedKey.length == 0) {
        return NO;
    }
    NSString *key = [normalizedKey hasPrefix:@"#"] ? [normalizedKey substringFromIndex:1] : normalizedKey;
    return [key isEqualToString:@"random"] || [key isEqualToString:@"random_gradient"] || [key isEqualToString:@"rainbow_rotating"];
}

// 通过 NSClassFromString(@"YYImageDecoder") 反射创建 YYImage 的解码器，而不是直接
// #import <YYImage/YYImageDecoder.h>。原因：tweak 运行在宿主 App（抖音）进程里，
// YYImage 库可能存在也可能不存在、版本还可能不同，直接链接/导入会导致启动崩溃。
// 用"类名字符串 + respondsToSelector"探测：库在就用，不在就返回 nil 走兜底逻辑。
// 这是 tweak 里最常见的"运行时软依赖"写法，本文件多处用到。
static YYImageDecoder *DYYYUtilsCreateYYDecoderWithData(NSData *data, CGFloat scale) {
    if (!data || data.length == 0) {
        return nil;
    }

    Class decoderClass = NSClassFromString(@"YYImageDecoder");
    if (!decoderClass || ![decoderClass respondsToSelector:@selector(decoderWithData:scale:)]) {
        return nil;
    }

    CGFloat resolvedScale = scale > 0 ? scale : 1.0f;
    id decoderInstance = [(id)decoderClass decoderWithData:data scale:resolvedScale];
    if (![decoderInstance isKindOfClass:decoderClass]) {
        return nil;
    }

    return (YYImageDecoder *)decoderInstance;
}

static CGFloat DYYYUtilsTotalDurationFromYYDecoder(YYImageDecoder *decoder) {
    if (!decoder || decoder.frameCount == 0) {
        return 0;
    }

    CGFloat totalDuration = 0;
    NSUInteger frameCount = decoder.frameCount;
    for (NSUInteger i = 0; i < frameCount; i++) {
        YYImageFrame *frame = [decoder frameAtIndex:i decodeForDisplay:NO];
        if (!frame) {
            continue;
        }
        CGFloat frameDuration = frame.duration > 0 ? frame.duration : kDYYYUtilsDefaultFrameDelay;
        totalDuration += frameDuration;
    }

    return totalDuration;
}

// ==== 二进制解析区块 ====
// 下面几个函数直接解析 MP4/HEIF 容器的字节，目的是从动图/视频文件里读出时长。
// 为什么手动解析而不是用现成 API？系统 API 不提供"读文件头时长"的便捷入口，
// 而 tweak 也不想为了读个时长引入视频解析库。
// 注意大小端：MP4/HEIF 的 box 头是网络字节序（大端），而 x86/ARM 内存里是小端，
// 所以必须先手工把 4/8 个字节拼成整数（ReadUInt32/64BigEndian），否则数值颠倒。
// MP4 结构 = 一层层 box（长度 + 类型 + 数据）；mvhd 子 box 记录 timescale 与
// duration，时长 = duration / timescale。下面的函数就是在递归找 mvhd 这个 box。
static uint32_t DYYYUtilsReadUInt32BigEndian(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint64_t DYYYUtilsReadUInt64BigEndian(const uint8_t *bytes) {
    uint64_t value = 0;
    for (NSUInteger i = 0; i < 8; i++) {
        value = (value << 8) | (uint64_t)bytes[i];
    }
    return value;
}

static NSTimeInterval DYYYUtilsParseMVHDDuration(const uint8_t *bytes, NSUInteger length) {
    NSUInteger position = 0;
    while (position + 8 <= length) {
        uint64_t rawSize = DYYYUtilsReadUInt32BigEndian(bytes + position);
        NSUInteger header = 8;

        if (rawSize == 1) {
            if (position + 16 > length) {
                break;
            }
            rawSize = DYYYUtilsReadUInt64BigEndian(bytes + position + 8);
            header = 16;
        } else if (rawSize == 0) {
            rawSize = length - position;
        }

        if (rawSize < header || position + rawSize > length) {
            break;
        }

        const uint8_t *typePtr = bytes + position + 4;
        if (typePtr[0] == 'm' && typePtr[1] == 'v' && typePtr[2] == 'h' && typePtr[3] == 'd') {
            const uint8_t *payload = bytes + position + header;
            NSUInteger payloadLength = (NSUInteger)rawSize - header;
            if (payloadLength < 20) {
                break;
            }

            uint8_t version = payload[0];
            if (version == 0) {
                uint32_t timescale = DYYYUtilsReadUInt32BigEndian(payload + 12);
                uint32_t duration = DYYYUtilsReadUInt32BigEndian(payload + 16);
                if (timescale > 0) {
                    return (NSTimeInterval)duration / (NSTimeInterval)timescale;
                }
            } else if (version == 1) {
                if (payloadLength < 32) {
                    break;
                }
                uint32_t timescale = DYYYUtilsReadUInt32BigEndian(payload + 20);
                uint64_t duration = DYYYUtilsReadUInt64BigEndian(payload + 24);
                if (timescale > 0) {
                    return (NSTimeInterval)duration / (NSTimeInterval)timescale;
                }
            }
        }

        position += (NSUInteger)rawSize;
    }

    return 0;
}

static NSTimeInterval DYYYUtilsParseHEIFDuration(const uint8_t *bytes, NSUInteger length) {
    NSUInteger position = 0;
    while (position + 8 <= length) {
        uint64_t rawSize = DYYYUtilsReadUInt32BigEndian(bytes + position);
        NSUInteger header = 8;

        if (rawSize == 1) {
            if (position + 16 > length) {
                break;
            }
            rawSize = DYYYUtilsReadUInt64BigEndian(bytes + position + 8);
            header = 16;
        } else if (rawSize == 0) {
            rawSize = length - position;
        }

        if (rawSize < header || position + rawSize > length) {
            break;
        }

        const uint8_t *typePtr = bytes + position + 4;
        if (typePtr[0] == 'm' && typePtr[1] == 'o' && typePtr[2] == 'o' && typePtr[3] == 'v') {
            NSTimeInterval duration = DYYYUtilsParseMVHDDuration(bytes + position + header, (NSUInteger)rawSize - header);
            if (duration > 0) {
                return duration;
            }
        }

        position += (NSUInteger)rawSize;
    }

    return 0;
}

static NSTimeInterval DYYYUtilsHEIFDurationFromData(NSData *data) {
    if (!data || data.length < 16) {
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    return DYYYUtilsParseHEIFDuration(bytes, data.length);
}

static NSURL *DYYYUtilsTemporaryGIFURLForSourceURL(NSURL *sourceURL) {
    NSString *baseName = sourceURL.lastPathComponent.stringByDeletingPathExtension;
    if (baseName.length == 0) {
        baseName = @"image";
    }
    NSString *fileName = [NSString stringWithFormat:@"%@_%@.gif", baseName, [[NSUUID UUID] UUIDString]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    return [NSURL fileURLWithPath:path];
}

// 用 Core Graphics 的 CGImageDestination 把解码出的每一帧写成 GIF 文件：
// CGImageDestination 是 C 语言级别的"图像编码器"，可逐帧添加图片并携带帧参数
// （这里设置了循环次数和每帧延迟），最后 CGImageDestinationFinalize 才真正落盘。
// 注意 __bridge：Core Foundation 与 Foundation 对象互转需要桥接，__bridge 表示
// "只转指针、不转移所有权"，配合后面的 CFRelease 手动释放 C 对象。
static BOOL DYYYUtilsWriteGIFUsingYYDecoder(YYImageDecoder *decoder, NSURL *gifURL, NSTimeInterval fallbackTotalDuration) {
    if (!decoder || decoder.frameCount == 0) {
        return NO;
    }

    NSUInteger frameCount = (NSUInteger)decoder.frameCount;
    CGFloat fallbackFrameDuration = 0;
    if (fallbackTotalDuration > 0 && frameCount > 0) {
        fallbackFrameDuration = fallbackTotalDuration / frameCount;
    }
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)gifURL, kUTTypeGIF, frameCount, NULL);
    if (!dest) {
        return NO;
    }

    NSDictionary *gifProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFLoopCount : @0}};
    CGImageDestinationSetProperties(dest, (__bridge CFDictionaryRef)gifProperties);

    BOOL hasFrame = NO;
    for (NSUInteger i = 0; i < frameCount; i++) {
        YYImageFrame *frame = [decoder frameAtIndex:i decodeForDisplay:YES];
        UIImage *image = frame.image;
        CGImageRef imageRef = image.CGImage;
        if (!imageRef) {
            continue;
        }

        CGFloat frameDuration = frame.duration;
        if ((!isfinite(frameDuration) || frameDuration <= 0) && fallbackFrameDuration > 0) {
            frameDuration = fallbackFrameDuration;
        }
        CGFloat delay = DYYYUtilsNormalizedDelay(frameDuration);
        NSDictionary *frameProps = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFDelayTime : @(delay)}};
        CGImageDestinationAddImage(dest, imageRef, (__bridge CFDictionaryRef)frameProps);
        hasFrame = YES;
    }

    BOOL success = hasFrame ? CGImageDestinationFinalize(dest) : NO;
    CFRelease(dest);
    return success;
}

static BOOL DYYYUtilsConvertAnimatedDataWithYYDecoder(NSData *data, NSURL *gifURL, CGFloat scale) {
    YYImageDecoder *decoder = DYYYUtilsCreateYYDecoderWithData(data, scale);
    if (!decoder) {
        return NO;
    }
    return DYYYUtilsWriteGIFUsingYYDecoder(decoder, gifURL, 0);
}

static BOOL DYYYUtilsWriteStaticImageToGIF(UIImage *image, NSURL *gifURL) {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) {
        return NO;
    }

    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)gifURL, kUTTypeGIF, 1, NULL);
    if (!dest) {
        return NO;
    }

    NSDictionary *gifProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFLoopCount : @0}};
    CGImageDestinationSetProperties(dest, (__bridge CFDictionaryRef)gifProperties);

    NSDictionary *frameProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFDelayTime : @(kDYYYUtilsDefaultFrameDelay)}};
    CGImageDestinationAddImage(dest, imageRef, (__bridge CFDictionaryRef)frameProperties);

    BOOL success = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return success;
}

@interface DYYYUtils ()
+ (NSString *)fallbackLocationFromIPAttribution:(AWEAwemeModel *)model;
+ (NSString *)displayLocationForGeoNamesError:(NSError *)error model:(AWEAwemeModel *)model;
+ (id)dyyy_safeValueForKey:(NSString *)key fromObject:(id)object;
+ (BOOL)dyyy_objectContainsMeaningfulAdPayload:(id)object;
@end

@implementation DYYYUtils

static const void *kCurrentIPRequestCityCodeKey = &kCurrentIPRequestCityCodeKey;

#pragma mark - 设置读取缓存（热路径性能）

// 缓存失效：面板写入走 setUserDefaults，由 SettingsHelper 调 invalidate；
// 跨进程同步走 NSUserDefaultsDidChangeNotification。
+ (void)invalidateSettingsCache {
    s_settingsCache = nil;
}

+ (id)fastSettingValueForKey:(NSString *)key {
    if (!s_settingsCache) {
        s_settingsCache = [NSMutableDictionary dictionary];
        // 观察者注册延后到启动完成后：iOS 15.4.1 上启动早期（首个 setFrame
        // 热路径触发）注册 NSUserDefaultsDidChangeNotification 会把 CF 通知
        // 注册器写坏（SIGBUS），表现为后续任何观察者注册/通知派发崩溃。
        // setUserDefaults 写路径已调用 invalidateSettingsCache，跨进程同步
        // 等启动后 2 秒再接管。
        if (!s_settingsObserverScheduled) {
            s_settingsObserverScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                                object:nil
                                                                 queue:nil
                                                            usingBlock:^(NSNotification *_Nonnull note) {
                                                              s_settingsCache = nil;
                                                            }];
            });
        }
    }
    id cached = s_settingsCache[key];
    if (cached) {
        return (cached == (id)[NSNull null]) ? nil : cached;
    }
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    // 用 NSNull 占位"未设置"，避免每次未命中都重新查 defaults
    s_settingsCache[key] = value ?: [NSNull null];
    return value;
}

+ (BOOL)fastBoolForKey:(NSString *)key {
    return [[self fastSettingValueForKey:key] boolValue];
}

+ (CGFloat)fastFloatForKey:(NSString *)key {
    return [[self fastSettingValueForKey:key] floatValue];
}

+ (NSString *)fastStringForKey:(NSString *)key {
    return [self fastSettingValueForKey:key];
}

// ==== 功能区块一：模型过滤（去广告的核心判断） ====
// 抖音的列表数据模型（AWEAwemeModel 等）来自宿主 App 的私有类，本文件顶部只
// import 了 AwemeHeaders.h（越狱社区对抖音私有头文件的逆向产物）。私有类在
// 抖音升级后可能改名/删方法，所以这里大量使用 NSClassFromString /
// respondsToSelector 探测，缺了也不崩，最多导致该功能不生效。
#pragma mark - Public Model Filtering Utilities (公共模型过滤工具)

// 安全版 KVC：valueForKey: 在键不存在时不是返回 nil，而是抛 NSException。
// 在 tweak 场景（目标 App 结构随时会变）里取值必须先 @try/@catch 包住，
// 否则一个异常就能让整个插件崩溃。
+ (id)dyyy_safeValueForKey:(NSString *)key fromObject:(id)object {
    if (!object || key.length == 0) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

+ (BOOL)dyyy_objectContainsMeaningfulAdPayload:(id)object {
    if (!object || object == [NSNull null]) {
        return NO;
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *value = [(NSString *)object stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return value.length > 0 && ![value isEqualToString:@"{}"] && ![value isEqualToString:@"[]"] && ![value isEqualToString:@"null"];
    }
    if ([object isKindOfClass:[NSData class]]) {
        return [(NSData *)object length] > 0;
    }
    if ([object isKindOfClass:[NSDictionary class]] || [object isKindOfClass:[NSArray class]]) {
        return [object count] > 0;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)object boolValue];
    }
    return NO;
}

// 逐个探测抖音模型上可能存在的"广告判定"方法并调用。
// 注意这里用 objc_msgSend 而不是 performSelector:——performSelector: 拿不到
// BOOL 返回值（它只返回 id），所以手工声明函数指针类型 (BOOL(*)(id, SEL))，
// 再以 C 函数方式直接给对象发消息。这是 tweak 调用私有方法并取标量返回值的
// 常用手法，本文件多处可见。
+ (BOOL)isAdvertisementAwemeModel:(id)model {
    Class awemeModelClass = NSClassFromString(@"AWEAwemeModel");
    if (!model || !awemeModelClass || ![model isKindOfClass:awemeModelClass]) {
        return NO;
    }

    // 仅信任抖音模型自身明确的广告布尔判定，避免把常驻的广告能力占位对象误当成广告。
    for (NSString *selectorName in @[ @"checkIsAd", @"isHardAdModel", @"isHardAd", @"isAds" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([model respondsToSelector:selector]) {
            BOOL (*sendBool)(id, SEL) = (BOOL(*)(id, SEL))objc_msgSend;
            if (sendBool(model, selector)) {
                return YES;
            }
        }
    }

    return NO;
}

+ (BOOL)isAdvertisementContainerModel:(id)model {
    if ([self isAdvertisementAwemeModel:model]) {
        return YES;
    }

    Class searchModelClass = NSClassFromString(@"AWEGeneralSearchModel");
    if (!searchModelClass || ![model isKindOfClass:searchModelClass]) {
        return NO;
    }

    // 搜索模型中的模块、卡片名和卡片类型在正常作品中也可能作为能力占位常驻，不能单独作为广告证据。
    id dynamicPatch = [self dyyy_safeValueForKey:@"commonDynamicPatchModel" fromObject:model];
    id isAdValue = [self dyyy_safeValueForKey:@"is_ad" fromObject:dynamicPatch];
    if ([isAdValue respondsToSelector:@selector(boolValue)] && [isAdValue boolValue]) {
        return YES;
    }

    for (NSString *selectorName in @[ @"aweme", @"awemeInVideoFeed" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![model respondsToSelector:selector]) {
            continue;
        }
        id (*sendObject)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
        if ([self isAdvertisementAwemeModel:sendObject(model, selector)]) {
            return YES;
        }
    }

    return NO;
}

+ (NSArray *)arrayByRemovingAdvertisements:(id)array {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYNoAds"] || ![array isKindOfClass:[NSArray class]]) {
        return array;
    }

    NSArray *source = (NSArray *)array;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:source.count];
    for (id model in source) {
        if (![self isAdvertisementContainerModel:model]) {
            [filtered addObject:model];
        }
    }

    if (filtered.count == source.count) {
        return array;
    }
    return [array isKindOfClass:[NSMutableArray class]] ? filtered : [filtered copy];
}

+ (BOOL)isAdvertisementRawData:(id)rawData {
    if (![rawData isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSDictionary *dictionary = (NSDictionary *)rawData;
    for (NSString *flagKey in @[ @"is_ads", @"is_ad" ]) {
        id value = dictionary[flagKey];
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) {
            return YES;
        }
    }

    // 仅检查名称本身就代表广告原始载荷的字段；普通作品也可能带有通用 ad_info 能力配置。
    for (NSString *payloadKey in @[ @"aweme_raw_ad", @"raw_ad_data" ]) {
        if ([self dyyy_objectContainsMeaningfulAdPayload:dictionary[payloadKey]]) {
            return YES;
        }
    }

    for (NSString *containerKey in @[ @"aweme", @"aweme_info", @"item", @"common_dynamic_patch_model" ]) {
        if ([self isAdvertisementRawData:dictionary[containerKey]]) {
            return YES;
        }
    }

    return NO;
}

static NSString *DYYYJSONStringFromObject(id object) {
    if (!object) {
        return nil;
    }
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return nil;
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (error || jsonData.length == 0) {
        return nil;
    }

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

static NSString *DYYYDisplayLocationFromGeoNamesInfo(NSDictionary *locationInfo) {
    if (![locationInfo isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *countryName = locationInfo[@"countryName"];
    NSString *adminName1 = locationInfo[@"adminName1"];
    NSString *localName = locationInfo[@"name"];

    if (![countryName isKindOfClass:[NSString class]]) {
        countryName = nil;
    }
    if (![adminName1 isKindOfClass:[NSString class]]) {
        adminName1 = nil;
    }
    if (![localName isKindOfClass:[NSString class]]) {
        localName = nil;
    }

    if (countryName.length > 0) {
        if (adminName1.length > 0 && localName.length > 0 && ![countryName isEqualToString:localName]) {
            if ([adminName1 isEqualToString:localName]) {
                return [NSString stringWithFormat:@"%@ %@", countryName, localName];
            }
            return [NSString stringWithFormat:@"%@ %@ %@", countryName, adminName1, localName];
        }
        if (localName.length > 0 && ![countryName isEqualToString:localName]) {
            return [NSString stringWithFormat:@"%@ %@", countryName, localName];
        }
        if (adminName1.length > 0 && ![countryName isEqualToString:adminName1]) {
            return [NSString stringWithFormat:@"%@ %@", countryName, adminName1];
        }
        return countryName;
    }

    if (localName.length > 0) {
        return localName;
    }
    if (adminName1.length > 0) {
        return adminName1;
    }

    return nil;
}

static void DYYYApplyDisplayLocationToLabel(UILabel *label, NSString *displayLocation, NSString *colorHexString) {
    if (!label) {
        return;
    }

    NSString *resolvedLocation = displayLocation ?: @"";
    resolvedLocation = [resolvedLocation stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (resolvedLocation.length == 0) {
        resolvedLocation = @"未知";
    }

    NSString *currentLabelText = label.text ?: @"";
    NSString *newText = nil;
    NSRange ipRange = [currentLabelText rangeOfString:@"IP属地："];
    if (ipRange.location != NSNotFound) {
        NSString *baseText = [currentLabelText substringToIndex:ipRange.location];
        newText = [NSString stringWithFormat:@"%@IP属地：%@", baseText, resolvedLocation];
    } else {
        if (currentLabelText.length > 0) {
            newText = [NSString stringWithFormat:@"%@  IP属地：%@", currentLabelText, resolvedLocation];
        } else {
            newText = [NSString stringWithFormat:@"IP属地：%@", resolvedLocation];
        }
    }

    if (newText.length > 0 && ![label.text isEqualToString:newText]) {
        label.text = newText;
    } else if (label.text.length == 0) {
        label.text = newText;
    }

    [DYYYUtils applyColorSettingsToLabel:label colorHexString:colorHexString];
}

// ==== 关键方法：给作品标签打上"IP 属地" ====
// 这是"内存缓存 -> 磁盘缓存 -> 网络请求 -> 回主线程刷新 UI"的完整示例，值得逐行读：
// 1. objc_setAssociatedObject 把本次请求的城市码挂到 label 上；网络回调回来时用
//    objc_getAssociatedObject 对比：如果用户已滚动到别的作品（城市码变了），就
//    丢弃这次结果，避免旧数据覆盖新标签。这是无锁的"防竞态"写法。
// 2. 缓存分两级：NSCache（进程内内存缓存，App 被杀即失）+ 沙盒 Caches 目录下的
//    plist 文件（磁盘缓存，下次启动还在），命中就直接用，不发网络请求。
// 3. 所有 UI 更新（改 label.text）都 dispatch_async 回主线程——UIKit 不是线程
//    安全的，网络回调运行在后台线程，直接改 UI 会崩溃或闪烁。
+ (void)processAndApplyIPLocationToLabel:(UILabel *)label forModel:(AWEAwemeModel *)model withLabelColor:(NSString *)colorHexString {
    NSString *originalText = label.text ?: @"";
    NSString *cityCode = model.cityCode;

    if (cityCode.length == 0) {
        return;
    }

    objc_setAssociatedObject(label, kCurrentIPRequestCityCodeKey, cityCode, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSString *cityName = [CityManager.sharedInstance getCityNameWithCode:cityCode];
    NSString *provinceName = [CityManager.sharedInstance getProvinceNameWithCode:cityCode];

    if (!cityName || cityName.length == 0) {
        NSString *cacheKey = cityCode;
        static NSCache *geoNamesCache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          geoNamesCache = [[NSCache alloc] init];
          geoNamesCache.name = @"com.dyyy.geonames.cache";
          geoNamesCache.countLimit = 1000;
        });

        // 1 & 2. 查内存和磁盘缓存
        NSDictionary *cachedData = [geoNamesCache objectForKey:cacheKey];
        if (!cachedData) {
            NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString *geoNamesCacheDir = [cachesDir stringByAppendingPathComponent:@"DYYYGeoNamesCache"];
            NSFileManager *fileManager = [NSFileManager defaultManager];
            if (![fileManager fileExistsAtPath:geoNamesCacheDir]) {
                [fileManager createDirectoryAtPath:geoNamesCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            NSString *cacheFilePath = [geoNamesCacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", cacheKey]];
            if ([fileManager fileExistsAtPath:cacheFilePath]) {
                cachedData = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
                if (cachedData) {
                    [geoNamesCache setObject:cachedData forKey:cacheKey];
                }
            }
        }

        // 3. 处理缓存数据或发起网络请求
        if (cachedData) {
            NSString *displayLocation = DYYYDisplayLocationFromGeoNamesInfo(cachedData) ?: @"未知";

            if (displayLocation.length == 0 || [displayLocation isEqualToString:@"未知"]) {
                NSString *fallbackLocation = [DYYYUtils fallbackLocationFromIPAttribution:model];
                if (fallbackLocation.length > 0) {
                    displayLocation = fallbackLocation;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
              NSString *currentRequestCode = objc_getAssociatedObject(label, kCurrentIPRequestCityCodeKey);
              if (![currentRequestCode isEqualToString:cityCode]) {
                  return;
              }

              DYYYApplyDisplayLocationToLabel(label, displayLocation, colorHexString);
            });
        } else {
            [CityManager fetchLocationWithGeonameId:cityCode
                                  completionHandler:^(NSDictionary *locationInfo, NSError *error) {
                                    __block NSString *displayLocation = @"未知";

                                    if (error) {
                                        if ([error.domain isEqualToString:DYYYGeonamesErrorDomain]) {
                                            displayLocation = [DYYYUtils displayLocationForGeoNamesError:error model:model];
                                        } else {
                                            NSLog(@"[DYYY] GeoNames fetch failed: %@", error.localizedDescription);
                                            NSString *fallbackLocation = [DYYYUtils fallbackLocationFromIPAttribution:model];
                                            if (fallbackLocation.length > 0) {
                                                displayLocation = fallbackLocation;
                                            }
                                        }
                                    } else if (locationInfo) {
                                        BOOL shouldCacheLocation = NO;

                                        NSString *resolvedLocation = DYYYDisplayLocationFromGeoNamesInfo(locationInfo);
                                        if (resolvedLocation.length > 0) {
                                            displayLocation = resolvedLocation;
                                            shouldCacheLocation = YES;
                                        }

                                        if (displayLocation.length == 0 || [displayLocation isEqualToString:@"未知"]) {
                                            NSString *fallbackLocation = [DYYYUtils fallbackLocationFromIPAttribution:model];
                                            if (fallbackLocation.length > 0) {
                                                displayLocation = fallbackLocation;
                                            }
                                            shouldCacheLocation = NO;
                                        }

                                        if (shouldCacheLocation && ![displayLocation isEqualToString:@"未知"]) {
                                            [geoNamesCache setObject:locationInfo forKey:cacheKey];
                                            NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
                                            NSString *geoNamesCacheDir = [cachesDir stringByAppendingPathComponent:@"DYYYGeoNamesCache"];
                                            NSString *cacheFilePath = [geoNamesCacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", cacheKey]];
                                            [locationInfo writeToFile:cacheFilePath atomically:YES];
                                            // 磁盘缓存只增不删，写入后顺带做上限清理
                                            DYYYTrimGeoNamesDiskCache();
                                        }
                                    }

                                    dispatch_async(dispatch_get_main_queue(), ^{
                                      NSString *currentRequestCode = objc_getAssociatedObject(label, kCurrentIPRequestCityCodeKey);
                                      if (![currentRequestCode isEqualToString:cityCode]) {
                                          return;
                                      }

                                      DYYYApplyDisplayLocationToLabel(label, displayLocation, colorHexString);
                                    });
                                  }];
        }
    }

    else if (![originalText containsString:cityName]) {
        BOOL isDirectCity = [provinceName isEqualToString:cityName] || ([cityCode hasPrefix:@"11"] || [cityCode hasPrefix:@"12"] || [cityCode hasPrefix:@"31"] || [cityCode hasPrefix:@"50"]);
        if (!model.ipAttribution) {
            if (isDirectCity) {
                label.text = [NSString stringWithFormat:@"%@  IP属地：%@", originalText, cityName];
            } else {
                label.text = [NSString stringWithFormat:@"%@  IP属地：%@ %@", originalText, provinceName, cityName];
            }
        } else {
            BOOL containsProvince = [originalText containsString:provinceName];
            BOOL containsCity = [originalText containsString:cityName];
            if (containsProvince && !isDirectCity && !containsCity) {
                label.text = [NSString stringWithFormat:@"%@ %@", originalText, cityName];
            } else if (isDirectCity && !containsCity) {
                label.text = [NSString stringWithFormat:@"%@  IP属地：%@", originalText, cityName];
            }
        }
        [DYYYUtils applyColorSettingsToLabel:label colorHexString:colorHexString];
    }
}

+ (NSString *)fallbackLocationFromIPAttribution:(AWEAwemeModel *)model {
    if (!model) {
        return nil;
    }

    NSString *rawAttribution = nil;
    @try {
        rawAttribution = model.ipAttribution;
    } @catch (NSException *exception) {
        return nil;
    }

    if (![rawAttribution isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *trimmedValue = [rawAttribution stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedValue.length == 0) {
        return nil;
    }

    NSArray<NSString *> *prefixes = @[ @"IP属地：", @"IP属地:", @"IP 属地：", @"IP 属地:" ];
    for (NSString *prefix in prefixes) {
        if ([trimmedValue hasPrefix:prefix]) {
            trimmedValue = [trimmedValue substringFromIndex:prefix.length];
            break;
        }
    }

    trimmedValue = [trimmedValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return trimmedValue.length > 0 ? trimmedValue : nil;
}

+ (NSString *)displayLocationForGeoNamesError:(NSError *)error model:(AWEAwemeModel *)model {
    NSString *fallbackLocation = [DYYYUtils fallbackLocationFromIPAttribution:model];
    if (fallbackLocation.length > 0) {
        return fallbackLocation;
    }

    NSDictionary *status = error.userInfo[DYYYGeonamesStatusUserInfoKey];
    if ([status isKindOfClass:[NSDictionary class]]) {
        NSString *statusJSON = DYYYJSONStringFromObject(@{@"status" : status});
        if (statusJSON.length > 0) {
            return [NSString stringWithFormat:@"未知 %@", statusJSON];
        }
    }

    NSString *message = error.localizedDescription ?: @"";
    message = [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (message.length > 0) {
        return [NSString stringWithFormat:@"未知 %@", message];
    }

    return @"未知";
}

// ==== 功能区块二：UI 工具 ====
// 插件经常要"在 App 界面上盖东西"或"找到某个控件"。下面这些方法负责：
// 拿当前窗口/顶层控制器、按类名在视图树里找控件、加毛玻璃、递归清背景、
// 弹 Toast、判断深浅色模式。调用宿主 App 内部类（如 DUXToast）时一律用
// 运行时三步曲：NSClassFromString 找类 -> respondsToSelector 确认方法 ->
// performSelector 调用，类不存在时静默跳过，不影响其他功能。
#pragma mark - Public UI Utilities (公共 UI/窗口/控制器 工具)

// 拿到"当前正在显示的窗口"。iOS 13 之后 App 可以多窗口（多 UIWindowScene 场景），
// 老 API keyWindow 已废弃且可能返回 nil，所以要遍历 connectedScenes 找激活中的
// 场景，再逐级回退（delegate.window -> windows.firstObject），保证各种状态下
// 都有返回值——这是兼容老版本系统的"回退链"写法。
+ (UIWindow *)getActiveWindow {
    UIWindow *fallbackWindow = [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].delegate.window ?: [UIApplication sharedApplication].windows.firstObject;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *activeScene = nil, *inactiveScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UISceneActivationState state = scene.activationState;
                if (state == UISceneActivationStateForegroundActive) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                } else if (state == UISceneActivationStateForegroundInactive) {
                    if (inactiveScene == nil) {
                        inactiveScene = (UIWindowScene *)scene;
                    }
                }
            }
        }

        UIWindowScene *targetScene = activeScene ?: inactiveScene;
        if (targetScene) {
            if (@available(iOS 15.0, *)) {
                return targetScene.keyWindow ?: targetScene.windows.firstObject ?: fallbackWindow;
            } else {
                UIWindow *firstVisibleWindow = nil;

                for (UIWindow *window in targetScene.windows) {
                    if (window.isKeyWindow) {
                        return window;
                    } else if (firstVisibleWindow == nil && !window.isHidden && window.rootViewController) {
                        firstVisibleWindow = window;
                    }
                }

                return firstVisibleWindow ?: targetScene.windows.firstObject ?: fallbackWindow;
            }
        }
    }

    return fallbackWindow;
}

+ (UIViewController *)topView {
    UIWindow *window = [self getActiveWindow];
    if (!window)
        return nil;

    UIViewController *topViewController = window.rootViewController;
    while (topViewController.presentedViewController) {
        topViewController = topViewController.presentedViewController;
    }
    return topViewController;
}

+ (UIViewController *)firstAvailableViewControllerFromView:(UIView *)view {
    UIResponder *responder = view;
    while ((responder = [responder nextResponder])) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

+ (UIViewController *)findViewControllerOfClass:(Class)targetClass inViewController:(UIViewController *)vc {
    if (!targetClass || !vc)
        return nil;

    if ([vc isKindOfClass:targetClass]) {
        return vc;
    }

    for (UIViewController *childVC in vc.childViewControllers) {
        UIViewController *found = [self findViewControllerOfClass:targetClass inViewController:childVC];
        if (found)
            return found;
    }

    return [self findViewControllerOfClass:targetClass inViewController:vc.presentedViewController];
}

+ (UIResponder *)findAncestorResponderOfClass:(Class)targetClass fromView:(UIView *)view {
    if (!view)
        return nil;
    UIResponder *responder = view.superview;
    while (responder) {
        if ([responder isKindOfClass:targetClass]) {
            return responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

+ (NSArray<__kindof UIView *> *)findAllSubviewsOfClass:(Class)targetClass inContainer:(id)container {
    if (!targetClass || !container) {
        return @[];
    }

    UIView *startView = nil;
    if ([container isKindOfClass:[UIView class]]) {
        startView = (UIView *)container;
    } else if ([container isKindOfClass:[UIViewController class]]) {
        startView = ((UIViewController *)container).view;
    }

    NSMutableArray *resultViews = [NSMutableArray array];
    [self _traverseViewHierarchy:startView
                        forClass:targetClass
                      usingBlock:^BOOL(UIView *foundView) {
                        [resultViews addObject:foundView];
                        return NO;
                      }];

    return [resultViews copy];
}

+ (__kindof UIView *)findSubviewOfClass:(Class)targetClass inContainer:(id)container {
    if (!targetClass || !container) {
        return nil;
    }

    UIView *startView = nil;
    if ([container isKindOfClass:[UIView class]]) {
        startView = (UIView *)container;
    } else if ([container isKindOfClass:[UIViewController class]]) {
        startView = ((UIViewController *)container).view;
    }

    __block UIView *resultView = nil;
    [self _traverseViewHierarchy:startView
                        forClass:targetClass
                      usingBlock:^BOOL(UIView *foundView) {
                        resultView = foundView;
                        return YES;
                      }];

    return resultView;
}

+ (__kindof UIView *)nearestCommonSuperviewOfViews:(NSArray<UIView *> *)views {
    if (views.count == 0)
        return nil;
    if (views.count == 1)
        return views.firstObject.superview;

    UIView *commonSuperview = views.firstObject;
    for (UIView *view in views) {
        commonSuperview = [self _nearestCommonSuperviewOfView:commonSuperview andView:view];
        if (!commonSuperview)
            break;
    }

    return commonSuperview;
}

+ (BOOL)containsSubviewOfClass:(Class)targetClass inContainer:(id)container {
    return [self findSubviewOfClass:targetClass inContainer:container] != nil;
}

+ (void)applyBlurEffectToView:(UIView *)view transparency:(float)userTransparency blurViewTag:(NSInteger)tag {
    if (!view)
        return;

    view.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *existingBlurView = nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == tag) {
            existingBlurView = (UIVisualEffectView *)subview;
            break;
        }
    }

    BOOL isDarkMode = [DYYYUtils isDarkMode];
    UIBlurEffectStyle blurStyle = isDarkMode ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;

    UIView *overlayView = nil;

    if (!existingBlurView) {
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:blurStyle];
        UIVisualEffectView *blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurEffectView.frame = view.bounds;
        blurEffectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurEffectView.alpha = userTransparency;
        blurEffectView.tag = tag;

        overlayView = [[UIView alloc] initWithFrame:view.bounds];
        overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [blurEffectView.contentView addSubview:overlayView];

        [view insertSubview:blurEffectView atIndex:0];
    } else {
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:blurStyle];
        [existingBlurView setEffect:blurEffect];
        existingBlurView.alpha = userTransparency;

        for (UIView *subview in existingBlurView.contentView.subviews) {
            if ([subview isKindOfClass:[UIView class]]) {
                overlayView = subview;
                break;
            }
        }
        if (!overlayView) {
            overlayView = [[UIView alloc] initWithFrame:existingBlurView.bounds];
            overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [existingBlurView.contentView addSubview:overlayView];
        }
    }
    if (overlayView) {
        CGFloat alpha = isDarkMode ? 0.2 : 0.1;
        overlayView.backgroundColor = [UIColor colorWithWhite:(isDarkMode ? 0 : 1) alpha:alpha];
    }
}

+ (void)clearBackgroundRecursivelyInView:(UIView *)view {
    if (!view)
        return;

    BOOL shouldClear = YES;

    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        shouldClear = NO;  // 不清除 UIVisualEffectView 本身的背景
    } else if (view.superview && [view.superview isKindOfClass:[UIVisualEffectView class]]) {
        shouldClear = NO;  // 不清除 UIVisualEffectView 的 contentView 的背景
    }

    if (shouldClear) {
        view.backgroundColor = [UIColor clearColor];
        view.opaque = NO;
    }

    for (UIView *subview in view.subviews) {
        [self clearBackgroundRecursivelyInView:subview];
    }
}

+ (void)showToast:(NSString *)text {
    Class toastClass = NSClassFromString(@"DUXToast");
    if (toastClass && [toastClass respondsToSelector:@selector(showText:)]) {
        [toastClass performSelector:@selector(showText:) withObject:text];
    }
}

+ (BOOL)usesDouyinLightBackground {
    Class themeManagerClass = NSClassFromString(@"AWEUIThemeManager");
    SEL isLightThemeSEL = NSSelectorFromString(@"isLightTheme");
    if (themeManagerClass && [themeManagerClass respondsToSelector:isLightThemeSEL]) {
        return ((BOOL(*)(id, SEL))objc_msgSend)(themeManagerClass, isLightThemeSEL);
    }

    id themeManager = nil;
    SEL sharedManagerSEL = NSSelectorFromString(@"sharedManager");
    SEL sharedInstanceSEL = NSSelectorFromString(@"sharedInstance");
    if (themeManagerClass && [themeManagerClass respondsToSelector:sharedManagerSEL]) {
        themeManager = [themeManagerClass performSelector:sharedManagerSEL];
    } else if (themeManagerClass && [themeManagerClass respondsToSelector:sharedInstanceSEL]) {
        themeManager = [themeManagerClass performSelector:sharedInstanceSEL];
    }

    if (themeManager) {
        if ([themeManager respondsToSelector:isLightThemeSEL]) {
            return ((BOOL(*)(id, SEL))objc_msgSend)(themeManager, isLightThemeSEL);
        }

        @try {
            id lightThemeValue = [themeManager valueForKey:@"isLightTheme"];
            if ([lightThemeValue respondsToSelector:@selector(boolValue)]) {
                return [lightThemeValue boolValue];
            }
        } @catch (NSException *exception) {
        }
    }

    if (@available(iOS 13.0, *)) {
        return [UIScreen mainScreen].traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark;
    }

    return YES;
}

+ (UIColor *)douyinColorNamed:(NSString *)colorName fallbackColor:(UIColor *)fallbackColor {
    if (colorName.length == 0) {
        return fallbackColor;
    }

    Class colorClass = NSClassFromString(@"AWEUIColor");
    SEL colorNamedSEL = NSSelectorFromString(@"colorNamed:");
    if (colorClass && [colorClass respondsToSelector:colorNamedSEL]) {
        @try {
            id color = ((id(*)(id, SEL, id))objc_msgSend)(colorClass, colorNamedSEL, colorName);
            if ([color isKindOfClass:[UIColor class]]) {
                return color;
            }
        } @catch (NSException *exception) {
        }
    }

    return fallbackColor;
}

+ (UIColor *)douyinInteractiveControlBackgroundColor {
    UIColor *fallbackColor =
        [self usesDouyinLightBackground] ? [UIColor colorWithRed:22.0 / 255.0 green:24.0 / 255.0 blue:35.0 / 255.0 alpha:8.0 / 255.0] : [UIColor colorWithWhite:1.0 alpha:15.0 / 255.0];
    return [self douyinColorNamed:@"BGCard2" fallbackColor:fallbackColor];
}

+ (UIColor *)douyinPanelBackgroundColor {
    UIColor *fallbackColor = [self usesDouyinLightBackground] ? [UIColor whiteColor] : [UIColor colorWithWhite:38.0 / 255.0 alpha:1.0];
    return [self douyinColorNamed:@"BGPanelTint" fallbackColor:fallbackColor];
}

+ (UIColor *)douyinSeparatorColor {
    UIColor *fallbackColor = [self usesDouyinLightBackground] ? [UIColor colorWithWhite:22.0 / 255.0 alpha:20.0 / 255.0] : [UIColor colorWithWhite:1.0 alpha:20.0 / 255.0];
    return [self douyinColorNamed:@"LineSecondary" fallbackColor:fallbackColor];
}

+ (BOOL)isDarkMode {
    if (![self usesDouyinLightBackground]) {
        return YES;
    }

    return NO;
}

// ==== 功能区块三：文件管理 ====
// 缓存/临时文件都放在 NSTemporaryDirectory() 或 Caches 目录：这两个目录系统会
// 定期清理、不算用户数据，适合放下载的临时资源，不会把用户存储空间撑爆，
// 也不需要在卸载时自己操心清理。
#pragma mark - Public File Management (公共文件管理)

+ (NSString *)formattedSize:(unsigned long long)size {
    NSString *dataSizeString;
    if (size < 1024) {
        dataSizeString = [NSString stringWithFormat:@"%llu B", size];
    } else if (size < 1024 * 1024) {
        dataSizeString = [NSString stringWithFormat:@"%.2f KB", (double)size / 1024.0];
    } else if (size < 1024 * 1024 * 1024) {
        dataSizeString = [NSString stringWithFormat:@"%.2f MB", (double)size / (1024.0 * 1024.0)];
    } else {
        dataSizeString = [NSString stringWithFormat:@"%.2f GB", (double)size / (1024.0 * 1024.0 * 1024.0)];
    }
    return dataSizeString;
}

+ (unsigned long long)directorySizeAtPath:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;

    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath];

    NSArray<NSURLResourceKey> *keys = @[ NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey ];

    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:directoryURL
                                          includingPropertiesForKeys:keys
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:^BOOL(NSURL *url, NSError *error) {
                                                          NSLog(@"Error enumerating %@: %@", url.path, error);
                                                          return YES;
                                                        }];

    for (NSURL *fileURL in enumerator) {
        NSError *resourceError;
        NSDictionary<NSURLResourceKey, id> *resourceValues = [fileURL resourceValuesForKeys:keys error:&resourceError];

        if (resourceError) {
            NSLog(@"Error getting resource values for %@: %@", fileURL.path, resourceError);
            continue;
        }

        NSNumber *isDirectory = resourceValues[NSURLIsDirectoryKey];
        NSNumber *isSymbolicLink = resourceValues[NSURLIsSymbolicLinkKey];
        if (isDirectory.boolValue || isSymbolicLink.boolValue) {
            continue;
        }

        NSNumber *fileSize = resourceValues[NSURLFileSizeKey];
        if (fileSize) {
            totalSize += fileSize.unsignedLongLongValue;
        } else {
            NSLog(@"Missing file size for %@", fileURL.path);
        }
    }
    return totalSize;
}

+ (void)removeAllContentsAtPath:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDir = NO;

    if (![fileManager fileExistsAtPath:directoryPath isDirectory:&isDir] || !isDir) {
        NSLog(@"[CacheClean] Path is not a directory or does not exist: %@", directoryPath);
        return;
    }

    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath];

    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:directoryURL
                                          includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey ]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:^BOOL(NSURL *url, NSError *enumError) {
                                                          NSLog(@"[CacheClean] Error enumerating directory %@: %@", url, enumError);
                                                          return YES;
                                                        }];

    NSMutableArray<NSURL *> *itemsToDelete = [NSMutableArray array];
    for (NSURL *itemURL in enumerator) {
        NSNumber *isSymbolicLink;
        [itemURL getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if ([isSymbolicLink boolValue]) {
            continue;
        }
        [itemsToDelete addObject:itemURL];
    }

    for (NSURL *itemURL in [itemsToDelete reverseObjectEnumerator]) {
        NSError *removeError = nil;
        if ([fileManager removeItemAtURL:itemURL error:&removeError]) {
            // NSLog(@"[CacheClean] Successfully removed: %@", itemURL.lastPathComponent);
        } else {
            NSLog(@"[CacheClean] Error removing %@: %@", itemURL.path, removeError);
        }
    }
}

// MARK: - Cache Utilities

+ (NSString *)cacheDirectory {
    NSString *tmpDir = NSTemporaryDirectory();
    if (!tmpDir) {
        tmpDir = @"/tmp";
    }
    NSString *cacheDir = [tmpDir stringByAppendingPathComponent:@"DYYY"];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fileManager fileExistsAtPath:cacheDir isDirectory:&isDir] || !isDir) {
        [fileManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    return cacheDir;
}

+ (void)clearCacheDirectory {
    NSString *cacheDir = [self cacheDirectory];
    [self removeAllContentsAtPath:cacheDir];
}

+ (NSString *)cachePathForFilename:(NSString *)filename {
    return [[self cacheDirectory] stringByAppendingPathComponent:filename];
}

// ==== 功能区块四：媒体工具 ====
// 和抖音的图片/视频打交道：识别文件真实格式、缩放图片、读动图时长、
// 生成 GIF / 保存到相册、WebP/HEIC 转 GIF、视频合并音频。
#pragma mark - Public Media Helper Methods (公共媒体工具方法)

// 通过"魔数（magic bytes）"识别文件真实格式：每种格式开头几个字节是固定的
// 特征值（GIF 的 "GIF8"、PNG 的 0x89PNG、JPEG 的 0xFFD8、WebP 的 RIFF....WEBP、
// HEIC 的 ftyp 等）。之所以不信任文件扩展名——抖音下载的资源扩展名可能乱标，
// 扩展名错了按错格式解析会直接失败，看字节最可靠。
+ (NSString *)detectFileFormat:(NSURL *)fileURL {
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil];
    if (!fileData || fileData.length < 12) {
        return @"unknown";
    }

    const unsigned char *bytes = [fileData bytes];

    if (bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == 'F' && bytes[8] == 'W' && bytes[9] == 'E' && bytes[10] == 'B' && bytes[11] == 'P') {
        return @"webp";
    }

    if (bytes[4] == 'f' && bytes[5] == 't' && bytes[6] == 'y' && bytes[7] == 'p') {
        if (fileData.length >= 16) {
            if (bytes[8] == 'h' && bytes[9] == 'e' && bytes[10] == 'i' && bytes[11] == 'c') {
                return @"heic";
            }
            if (bytes[8] == 'h' && bytes[9] == 'e' && bytes[10] == 'i' && bytes[11] == 'f') {
                return @"heif";
            }
            return @"heif";
        }
    }

    if (bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F') {
        return @"gif";
    }

    if (bytes[0] == 0x89 && bytes[1] == 'P' && bytes[2] == 'N' && bytes[3] == 'G') {
        return @"png";
    }

    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        return @"jpeg";
    }

    return @"unknown";
}

+ (NSString *)mediaTypeDescription:(MediaType)mediaType {
    switch (mediaType) {
        case MediaTypeVideo:
            return @"视频";
        case MediaTypeImage:
            return @"图片";
        case MediaTypeAudio:
            return @"音频";
        case MediaTypeHeic:
            return @"表情包";
        default:
            return @"文件";
    }
}

+ (UIImage *)resizeImage:(UIImage *)image toSize:(CGSize)size {
    if (!image || size.width <= 0 || size.height <= 0) {
        return image;
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage ?: image;
}

+ (CGRect)rectForImageAspectFit:(CGSize)imageSize inSize:(CGSize)containerSize {
    if (imageSize.width <= 0 || imageSize.height <= 0 || containerSize.width <= 0 || containerSize.height <= 0) {
        return CGRectZero;
    }

    CGFloat hScale = containerSize.width / imageSize.width;
    CGFloat vScale = containerSize.height / imageSize.height;
    CGFloat scale = MIN(hScale, vScale);

    CGFloat newWidth = imageSize.width * scale;
    CGFloat newHeight = imageSize.height * scale;

    CGFloat x = (containerSize.width - newWidth) / 2.0;
    CGFloat y = (containerSize.height - newHeight) / 2.0;

    return CGRectMake(x, y, newWidth, newHeight);
}

+ (CGAffineTransform)transformForAssetTrack:(AVAssetTrack *)track targetSize:(CGSize)targetSize {
    if (!track || targetSize.width <= 0 || targetSize.height <= 0) {
        return CGAffineTransformIdentity;
    }

    CGSize trackSize = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    trackSize = CGSizeMake(fabs(trackSize.width), fabs(trackSize.height));
    if (trackSize.width <= 0 || trackSize.height <= 0) {
        return track.preferredTransform;
    }

    CGFloat xScale = targetSize.width / trackSize.width;
    CGFloat yScale = targetSize.height / trackSize.height;
    CGFloat scale = MIN(xScale, yScale);

    CGAffineTransform transform = track.preferredTransform;
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));

    CGFloat xOffset = (targetSize.width - trackSize.width * scale) / 2.0;
    CGFloat yOffset = (targetSize.height - trackSize.height * scale) / 2.0;
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(xOffset, yOffset));

    return transform;
}

+ (CGAffineTransform)transformForImage:(UIImage *)image targetSize:(CGSize)targetSize {
    if (!image || targetSize.width <= 0 || targetSize.height <= 0 || image.size.width <= 0 || image.size.height <= 0) {
        return CGAffineTransformIdentity;
    }

    CGSize imageSize = image.size;
    CGFloat xScale = targetSize.width / imageSize.width;
    CGFloat yScale = targetSize.height / imageSize.height;
    CGFloat scale = MIN(xScale, yScale);

    CGAffineTransform transform = CGAffineTransformIdentity;
    transform = CGAffineTransformScale(transform, scale, scale);

    CGFloat xOffset = (targetSize.width - imageSize.width * scale) / 2.0;
    CGFloat yOffset = (targetSize.height - imageSize.height * scale) / 2.0;
    transform = CGAffineTransformTranslate(transform, xOffset / scale, yOffset / scale);

    return transform;
}

+ (BOOL)isBDImageWithHeifURL:(UIImage *)image {
    if (!image) {
        return NO;
    }

    if ([NSStringFromClass([image class]) containsString:@"BDImage"]) {
        if ([image respondsToSelector:@selector(bd_webURL)]) {
            NSURL *webURL = [image performSelector:@selector(bd_webURL)];
            if (webURL) {
                NSString *urlString = webURL.absoluteString;
                return [urlString containsString:@".heif"] || [urlString containsString:@".heic"];
            }
        }
    }

    return NO;
}

+ (NSArray *)getImagesFromYYAnimatedImageView:(YYAnimatedImageView *)imageView {
    if (!imageView || !imageView.image) {
        return nil;
    }
    if ([imageView.image respondsToSelector:@selector(images)]) {
        return [imageView.image performSelector:@selector(images)];
    }
    return nil;
}

// 读取动图总时长。难点：抖音不同版本/不同来源的动图，底层可能是 UIImage.images、
// YYAnimatedImage 协议、YYImageDecoder 或普通 UIImage，没有统一 API。所以这里
// 按优先级逐个探测，谁有数据用谁（多级兜底策略），最后再退回 KVC 取 duration。
+ (CGFloat)getDurationFromYYAnimatedImageView:(YYAnimatedImageView *)imageView {
    if (!imageView || !imageView.image) {
        return 0;
    }

    UIImage *image = imageView.image;

    if (image.images.count > 0) {
        NSTimeInterval builtInDuration = image.duration;
        if (builtInDuration <= 0) {
            builtInDuration = image.images.count * kDYYYUtilsDefaultFrameDelay;
        }
        return builtInDuration;
    }

    SEL frameCountSEL = NSSelectorFromString(@"animatedImageFrameCount");
    SEL frameDurationSEL = NSSelectorFromString(@"animatedImageDurationAtIndex:");
    if ([image respondsToSelector:frameCountSEL] && [image respondsToSelector:frameDurationSEL]) {
        NSUInteger frameCount = ((NSUInteger(*)(id, SEL))objc_msgSend)(image, frameCountSEL);
        if (frameCount > 0) {
            CGFloat totalDuration = 0;
            for (NSUInteger i = 0; i < frameCount; i++) {
                CGFloat frameDuration = ((CGFloat(*)(id, SEL, NSUInteger))objc_msgSend)(image, frameDurationSEL, i);
                totalDuration += frameDuration > 0 ? frameDuration : kDYYYUtilsDefaultFrameDelay;
            }
            if (totalDuration > 0) {
                return totalDuration;
            }
        }
    }

    SEL dataSEL = NSSelectorFromString(@"animatedImageData");
    NSData *animatedData = nil;
    if ([image respondsToSelector:dataSEL]) {
        animatedData = ((NSData * (*)(id, SEL)) objc_msgSend)(image, dataSEL);
    }
    if (animatedData.length > 0) {
        CGFloat scale = image.scale > 0 ? image.scale : 1.0f;
        YYImageDecoder *decoder = DYYYUtilsCreateYYDecoderWithData(animatedData, scale);
        CGFloat decoderDuration = DYYYUtilsTotalDurationFromYYDecoder(decoder);
        if (decoderDuration > 0) {
            return decoderDuration;
        }
    }

    if ([image respondsToSelector:@selector(duration)]) {
        NSTimeInterval duration = image.duration;
        if (duration > 0) {
            return duration;
        }
    }

    id durationValue = [image valueForKey:@"duration"];
    return [durationValue respondsToSelector:@selector(floatValue)] ? [durationValue floatValue] : 0;
}

+ (BOOL)framesFromAnimatedData:(NSData *)data scale:(CGFloat)scale images:(NSArray<UIImage *> *_Nullable *)images totalDuration:(CGFloat *_Nullable)totalDuration {
    if (images) {
        *images = nil;
    }
    if (totalDuration) {
        *totalDuration = 0;
    }
    if (!data.length) {
        return NO;
    }

    CGFloat resolvedScale = scale > 0 ? scale : 1.0f;
    YYImageDecoder *decoder = DYYYUtilsCreateYYDecoderWithData(data, resolvedScale);
    if (!decoder || decoder.frameCount == 0) {
        return NO;
    }

    NSMutableArray<UIImage *> *decodedFrames = [NSMutableArray arrayWithCapacity:decoder.frameCount];
    CGFloat durationAccumulator = 0;
    for (NSUInteger i = 0; i < decoder.frameCount; i++) {
        YYImageFrame *frame = [decoder frameAtIndex:i decodeForDisplay:YES];
        if (!frame || !frame.image) {
            continue;
        }
        [decodedFrames addObject:frame.image];
        durationAccumulator += DYYYUtilsNormalizedDelay(frame.duration);
    }

    if (decodedFrames.count == 0) {
        return NO;
    }

    if (images) {
        *images = [decodedFrames copy];
    }
    if (totalDuration) {
        *totalDuration = durationAccumulator > 0 ? durationAccumulator : decodedFrames.count * kDYYYUtilsDefaultFrameDelay;
    }

    return YES;
}

+ (BOOL)createGIFWithImages:(NSArray *)images duration:(CGFloat)duration path:(NSString *)path progress:(void (^)(float progress))progressBlock {
    if (images.count == 0 || path.length == 0) {
        return NO;
    }

    CGFloat safeDuration = duration > 0 ? duration : (0.1f * images.count);
    float frameDuration = safeDuration / images.count;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kUTTypeGIF, images.count, NULL);
    if (!destination) {
        return NO;
    }

    NSDictionary *gifProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFLoopCount : @0}};
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)gifProperties);

    for (NSUInteger i = 0; i < images.count; i++) {
        UIImage *image = images[i];
        NSDictionary *frameProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFDelayTime : @(frameDuration)}};
        CGImageDestinationAddImage(destination, image.CGImage, (__bridge CFDictionaryRef)frameProperties);
        if (progressBlock) {
            progressBlock((float)(i + 1) / images.count);
        }
    }

    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return success;
}

// 保存到系统相册：必须走 Photos 框架的 performChanges（系统会弹出授权框），
// 完成回调在系统队列里执行，这里再 dispatch_async 回主线程通知调用方，并顺手
// 删掉临时 GIF 文件。注意"回调要回主线程"是贯穿整个文件的约定。
+ (void)saveGIFToPhotoLibrary:(NSString *)path completion:(void (^)(BOOL success, NSError *error))completion {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
          PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
          [request addResourceWithType:PHAssetResourceTypePhoto fileURL:fileURL options:nil];
        }
        completionHandler:^(BOOL success, NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, error);
            }
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                NSLog(@"删除临时GIF文件失败: %@", removeError);
            }
          });
        }];
}

+ (void)saveGifToPhotoLibrary:(NSURL *)gifURL completion:(void (^)(BOOL success))completion {
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
          NSData *gifData = [NSData dataWithContentsOfURL:gifURL];
          PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
          PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
          options.uniformTypeIdentifier = @"com.compuserve.gif";
          [request addResourceWithType:PHAssetResourceTypePhoto data:gifData options:options];
        }
        completionHandler:^(BOOL success, NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                [DYYYUtils showToast:@"保存失败"];
            }
            [[NSFileManager defaultManager] removeItemAtPath:gifURL.path error:nil];
            if (completion) {
                completion(success);
            }
          });
        }];
}

+ (BOOL)videoHasAudio:(NSURL *)videoURL {
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    return audioTracks.count > 0;
}

+ (void)downloadAudioAndMergeWithVideo:(NSURL *)videoURL audioURL:(NSURL *)audioURL completion:(void (^)(BOOL success, NSURL *mergedURL))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSData *audioData = [NSData dataWithContentsOfURL:audioURL];
      if (!audioData) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(NO, nil);
            }
          });
          return;
      }

      NSString *audioPath = [DYYYUtils cachePathForFilename:[NSString stringWithFormat:@"temp_%@", audioURL.lastPathComponent]];
      NSURL *audioFile = [NSURL fileURLWithPath:audioPath];
      if (![audioData writeToURL:audioFile atomically:YES]) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(NO, nil);
            }
          });
          return;
      }

      [self mergeVideo:videoURL
             withAudio:audioFile
            completion:^(BOOL success, NSURL *mergedURL) {
              [[NSFileManager defaultManager] removeItemAtURL:audioFile error:nil];
              dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(success, mergedURL);
                }
              });
            }];
    });
}

// 视频+音频合成为新视频：AVFoundation 的轨道读写耗时较重，整个流程丢到全局后台
// 队列执行，避免卡住主线程（否则滑动列表会掉帧）。AVAssetExportSession 导出
// 本身也是异步的（exportAsynchronouslyWithCompletionHandler:），完成后同样
// dispatch_async 回主线程回调调用方。
+ (void)mergeVideo:(NSURL *)videoURL withAudio:(NSURL *)audioURL completion:(void (^)(BOOL success, NSURL *mergedURL))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
      AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
      AVAssetTrack *videoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
      AVAssetTrack *audioTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
      if (!videoTrack || !audioTrack) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(NO, nil);
            }
          });
          return;
      }

      AVMutableComposition *composition = [AVMutableComposition composition];
      AVMutableCompositionTrack *compVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
      [compVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:videoTrack atTime:kCMTimeZero error:nil];

      AVMutableCompositionTrack *compAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
      [compAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:audioTrack atTime:kCMTimeZero error:nil];

      NSString *outputPath = [DYYYUtils cachePathForFilename:[NSString stringWithFormat:@"merged_%@", videoURL.lastPathComponent]];
      NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
      if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
          [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
      }

      AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
      exportSession.outputURL = outputURL;
      exportSession.outputFileType = AVFileTypeMPEG4;
      [exportSession exportAsynchronouslyWithCompletionHandler:^{
        BOOL success = exportSession.status == AVAssetExportSessionStatusCompleted;
        if (!success) {
            NSLog(@"Merge export failed: %@", exportSession.error);
        } else {
            [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion) {
              completion(success, success ? outputURL : nil);
          }
        });
      }];
    });
}

+ (void)convertWebpToGifSafely:(NSURL *)webpURL completion:(void (^)(NSURL *gifURL, BOOL success))completion {
    if (!webpURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion) {
              completion(nil, NO);
          }
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSData *webpData = [NSData dataWithContentsOfURL:webpURL options:NSDataReadingMappedIfSafe error:nil];
      if (!webpData) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(nil, NO);
            }
          });
          return;
      }

      NSURL *gifURL = DYYYUtilsTemporaryGIFURLForSourceURL(webpURL);
      [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];

      BOOL success = DYYYUtilsConvertAnimatedDataWithYYDecoder(webpData, gifURL, 1.0f);
      if (!success) {
          UIImage *fallbackImage = [UIImage imageWithData:webpData];
          if (fallbackImage) {
              success = DYYYUtilsWriteStaticImageToGIF(fallbackImage, gifURL);
          }
      }

      if (!success) {
          [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            completion(success ? gifURL : nil, success);
        }
      });
    });
}

+ (void)convertHeicToGif:(NSURL *)heicURL completion:(void (^)(NSURL *gifURL, BOOL success))completion {
    if (!heicURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion) {
              completion(nil, NO);
          }
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSData *heicData = [NSData dataWithContentsOfURL:heicURL options:NSDataReadingMappedIfSafe error:nil];
      NSTimeInterval heifDuration = DYYYUtilsHEIFDurationFromData(heicData);
      NSURL *gifURL = DYYYUtilsTemporaryGIFURLForSourceURL(heicURL);
      [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];

      BOOL success = NO;
      NSString *failureReason = nil;

      if (!heicData || heicData.length == 0) {
          failureReason = @"读取HEIC数据失败或数据为空";
      } else {
          YYImageDecoder *decoder = DYYYUtilsCreateYYDecoderWithData(heicData, 1.0f);
          if (!decoder) {
              failureReason = @"无法通过YYImageDecoder解析HEIC数据，可能是资源不是动图或SDK不可用";
          } else if (decoder.frameCount == 0) {
              failureReason = @"YYImageDecoder未解析到任何帧，HEIC资源可能不是动图";
          } else {
              success = DYYYUtilsWriteGIFUsingYYDecoder(decoder, gifURL, heifDuration);
              if (!success) {
                  failureReason = @"YYImageDecoder写入GIF失败，可能是图像数据损坏或磁盘空间不足";
              }
          }
      }

      if (!success) {
          [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];
          if (failureReason.length > 0) {
              NSLog(@"[DYYY] convertHeicToGif失败: %@", failureReason);
          }
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            completion(success ? gifURL : nil, success);
        }
      });
    });
}

// ==== 功能区块五：颜色方案引擎 ====
// 把用户设置的字符串（"#FF0000" 十六进制、"random" 随机色、
// "rainbow_rotating" 旋转彩虹、"red,blue" 渐变）统一解析成 UIColor 或 CALayer。
// 颜色工具可能被多个线程同时调用，下面的全局状态配合了三种并发手段。
#pragma mark - Public Color Scheme Methods (公共颜色方案方法)

// 颜色方案的全局共享状态，三行对应三种线程安全手段（颜色工具会被多线程并发调用）：
// 1. atomic_uint_fast64_t：原子计数器，让"旋转彩虹"每帧自动轮换颜色；用
//    atomic_fetch_add 递增在并发下也不会算错，普通 uint 并发自增会丢值。
// 2. os_unfair_lock：低开销的互斥锁，保护"创建颜色 + 写缓存"临界区。它是苹果
//    官方推荐的新锁（替代已废弃的自旋锁），比 NSLock 更轻量。
// 3. NSCache 本身线程安全：读缓存不加锁，只有"写缓存"才进锁。
static NSCache *_gradientColorCache;
static NSArray<UIColor *> *_baseRainbowColors;
static atomic_uint_fast64_t _rainbowRotationCounter = 0;
static os_unfair_lock _staticColorCreationLock = OS_UNFAIR_LOCK_INIT;

// +initialize 方法在类第一次被使用时调用，且只调用一次，是线程安全的
+ (void)initialize {
    if (self == [DYYYUtils class]) {
        _gradientColorCache = [[NSCache alloc] init];
        _gradientColorCache.name = @"DYYYGradientColorCache";
        // 可以自定义缓存限制，例如：
        // _gradientColorCache.countLimit = 100; // 最大缓存对象数量
        // _gradientColorCache.totalCostLimit = 10 * 1024 * 1024; // 最大缓存成本（例如10MB）

        _baseRainbowColors = @[
            [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0],  // 红
            [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0],  // 橙
            [UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0],  // 黄
            [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0],  // 绿
            [UIColor colorWithRed:0.0 green:1.0 blue:1.0 alpha:1.0],  // 青
            [UIColor colorWithRed:0.0 green:0.0 blue:1.0 alpha:1.0],  // 蓝
            [UIColor colorWithRed:0.5 green:0.0 blue:0.5 alpha:1.0]   // 紫
        ];

        atomic_init(&_rainbowRotationCounter, 0);
    }
}

+ (void)applyTextColorRecursively:(UIColor *)color inView:(UIView *)view shouldExcludeViewBlock:(BOOL (^)(UIView *subview))excludeBlock {
    if (!view || !color)
        return;

    BOOL shouldExclude = NO;
    if (excludeBlock)
        shouldExclude = excludeBlock(view);

    if (!shouldExclude) {
        if ([view isKindOfClass:[UILabel class]]) {
            ((UILabel *)view).textColor = color;
        } else if ([view isKindOfClass:[UIButton class]]) {
            [(UIButton *)view setTitleColor:color forState:UIControlStateNormal];
        }
    }

    for (UIView *subview in view.subviews) {
        [self applyTextColorRecursively:color inView:subview shouldExcludeViewBlock:excludeBlock];
    }
}

+ (void)applyColorSettingsToLabel:(UILabel *)label colorHexString:(NSString *)colorHexString {
    if (!label)
        return;

    NSAttributedString *existingAttributed = nil;
    if ([label.attributedText isKindOfClass:[NSAttributedString class]] && label.attributedText.length > 0) {
        existingAttributed = label.attributedText;
    }

    NSString *textSignature = existingAttributed.string;
    if (textSignature.length == 0) {
        NSString *fallbackText = label.text ?: @"";
        textSignature = fallbackText;
    }

    if (textSignature.length == 0) {
        label.attributedText = [[NSAttributedString alloc] initWithString:@""];
        return;
    }

    UIFont *font = label.font ?: [UIFont systemFontOfSize:[UIFont systemFontSize]];
    NSString *fontName = font.fontName ?: @"";
    CGFloat fontSize = font.pointSize;

    NSString *normalizedKey = DYYYNormalizedColorKey(colorHexString);
    BOOL allowCache = normalizedKey.length == 0 ? YES : !DYYYColorKeyIsDynamic(normalizedKey);

    DYYYLabelColorState *state = objc_getAssociatedObject(label, &kLabelColorStateKey);
    if (allowCache && state && DYYYStringsEqual(state.textSignature, textSignature) && DYYYStringsEqual(state.colorKey, normalizedKey ?: @"") && DYYYStringsEqual(state.fontName, fontName) &&
        fabs(state.fontSize - fontSize) <= 0.01) {
        return;
    }

    NSMutableAttributedString *attributedText = nil;
    if (existingAttributed) {
        attributedText = [[NSMutableAttributedString alloc] initWithAttributedString:existingAttributed];
    } else {
        attributedText = [[NSMutableAttributedString alloc] initWithString:textSignature];
    }

    NSRange fullRange = NSMakeRange(0, attributedText.length);
    [attributedText removeAttribute:NSForegroundColorAttributeName range:fullRange];
    [attributedText removeAttribute:NSStrokeColorAttributeName range:fullRange];
    [attributedText removeAttribute:NSStrokeWidthAttributeName range:fullRange];
    [attributedText removeAttribute:NSShadowAttributeName range:fullRange];

    if (![attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:nil] && font) {
        [attributedText addAttribute:NSFontAttributeName value:font range:fullRange];
    }

    if (!colorHexString || colorHexString.length == 0) {
        [attributedText addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor] range:fullRange];
    } else {
        CGSize maxTextSize = CGSizeMake(CGFLOAT_MAX, label.bounds.size.height);
        CGRect textRect = [attributedText boundingRectWithSize:maxTextSize options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading context:nil];
        CGFloat actualTextWidth = MAX(1.0, ceil(textRect.size.width));

        UIColor *finalTextColor = [self colorFromSchemeHexString:colorHexString targetWidth:actualTextWidth];

        if (finalTextColor) {
            [attributedText addAttribute:NSForegroundColorAttributeName value:finalTextColor range:fullRange];
        } else {
            [attributedText addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor] range:fullRange];
        }
    }

    label.attributedText = attributedText;

    if (!state) {
        state = [[DYYYLabelColorState alloc] init];
        objc_setAssociatedObject(label, &kLabelColorStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.textSignature = [textSignature copy];
    state.colorKey = normalizedKey ?: @"";
    state.fontName = fontName;
    state.fontSize = fontSize;
}

+ (void)applyStrokeToLabel:(UILabel *)label strokeColor:(UIColor *)strokeColor strokeWidth:(CGFloat)strokeWidth {
    if (!label || label.attributedText.length == 0) {
        return;
    }
    NSMutableAttributedString *mutableAttributedText = [[NSMutableAttributedString alloc] initWithAttributedString:label.attributedText];
    NSRange fullRange = NSMakeRange(0, mutableAttributedText.length);

    // 先移除现有的描边属性，确保新的描边能完全生效
    [mutableAttributedText removeAttribute:NSStrokeColorAttributeName range:fullRange];
    [mutableAttributedText removeAttribute:NSStrokeWidthAttributeName range:fullRange];

    if (strokeColor && strokeWidth != 0) {  // 只有当描边颜色和宽度有效时才应用
        [mutableAttributedText addAttribute:NSStrokeColorAttributeName value:strokeColor range:fullRange];
        [mutableAttributedText addAttribute:NSStrokeWidthAttributeName value:@(strokeWidth) range:fullRange];
    }
    label.attributedText = mutableAttributedText;
}

+ (void)applyShadowToLabel:(UILabel *)label shadow:(NSShadow *)shadow {
    if (!label || label.attributedText.length == 0) {
        return;
    }
    NSMutableAttributedString *mutableAttributedText = [[NSMutableAttributedString alloc] initWithAttributedString:label.attributedText];
    NSRange fullRange = NSMakeRange(0, mutableAttributedText.length);

    // 先移除现有的阴影属性，确保新的阴影能完全生效
    [mutableAttributedText removeAttribute:NSShadowAttributeName range:fullRange];

    if (shadow) {  // 只有当阴影对象有效时才应用
        [mutableAttributedText addAttribute:NSShadowAttributeName value:shadow range:fullRange];
    }
    label.attributedText = mutableAttributedText;
}

// 颜色方案字符串 -> UIColor 的总入口，依次处理：random（随机纯色）、
// random_gradient（随机渐变）、rainbow_rotating（旋转彩虹）、普通十六进制/渐变。
// 注意方法中段的"双重检查锁"模式：先无锁读缓存（NSCache 线程安全，命中直接
// 返回，避免每次抢锁的开销），没命中才拿 os_unfair_lock 进临界区；进锁后再次
// 查缓存，确认没有别的线程已经生成过，然后创建并写回。这是并发场景下
// "先走快速路径、再走慢速路径"的典型写法。
+ (UIColor *)colorFromSchemeHexString:(NSString *)hexString targetWidth:(CGFloat)targetWidth {
    if (!hexString || hexString.length == 0) {
        return [UIColor whiteColor];
    }

    NSString *trimmedHexString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowercaseHexString = [trimmedHexString lowercaseString];

    // 1. 处理随机纯色（不缓存）
    if ([lowercaseHexString isEqualToString:@"random"] || [lowercaseHexString isEqualToString:@"#random"]) {
        return [self _randomColor];
    }
    // 2. 处理随机渐变（不缓存）
    if ([lowercaseHexString isEqualToString:@"random_gradient"] || [lowercaseHexString isEqualToString:@"#random_gradient"]) {
        NSArray<UIColor *> *randomGradientColors = @[ [self _randomColor], [self _randomColor], [self _randomColor] ];
        CGSize patternSize = CGSizeMake(MAX(1.0, ceil(targetWidth)), 1);
        UIImage *gradientImage = [self _imageWithGradientColors:randomGradientColors size:patternSize];
        if (gradientImage) {
            return [UIColor colorWithPatternImage:gradientImage];
        }
        return [UIColor whiteColor];  // Fallback
    }

    // 3. 处理旋转彩虹（缓存）
    CGFloat quantizedWidth = ceil(targetWidth);
    if ([lowercaseHexString isEqualToString:@"rainbow_rotating"] || [lowercaseHexString isEqualToString:@"#rainbow_rotating"]) {
        NSUInteger count = _baseRainbowColors.count;
        if (count == 0)
            return [UIColor whiteColor];

        uint_fast64_t currentRotationIndex = atomic_fetch_add(&_rainbowRotationCounter, 1) % count;

        NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f_idx_%llu", lowercaseHexString, quantizedWidth, currentRotationIndex];

        UIColor *cachedColor = [_gradientColorCache objectForKey:cacheKey];
        if (cachedColor) {
            return cachedColor;
        }

        NSArray<UIColor *> *rotatedColors = [self _rotatedRainbowColorsForIndex:currentRotationIndex];
        CGSize patternSize = CGSizeMake(MAX(1.0, quantizedWidth), 1);
        UIImage *gradientImage = [self _imageWithGradientColors:rotatedColors size:patternSize];

        if (gradientImage) {
            UIColor *finalColor = [UIColor colorWithPatternImage:gradientImage];
            if (finalColor)
                [_gradientColorCache setObject:finalColor forKey:cacheKey];
            return finalColor;
        }
        return [UIColor whiteColor];
    }

    // 4. 处理静态颜色（缓存）
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f", lowercaseHexString, quantizedWidth];

    UIColor *cachedColor = [_gradientColorCache objectForKey:cacheKey];
    if (cachedColor) {
        return cachedColor;
    }

    os_unfair_lock_lock(&_staticColorCreationLock);
    @try {
        cachedColor = [_gradientColorCache objectForKey:cacheKey];
        if (cachedColor)
            return cachedColor;

        UIColor *finalColor = nil;
        NSArray<UIColor *> *gradientColors = [self _staticGradientColorsForHexString:hexString];
        if (gradientColors && gradientColors.count > 0) {
            CGSize patternSize = CGSizeMake(MAX(1.0, quantizedWidth), 1);
            UIImage *gradientImage = [self _imageWithGradientColors:gradientColors size:patternSize];

            if (gradientImage) {
                finalColor = [UIColor colorWithPatternImage:gradientImage];
            }
        } else {
            UIColor *singleColor = [self _colorFromHexString:trimmedHexString];
            if (singleColor) {
                finalColor = singleColor;
            }
        }

        if (finalColor) {
            [_gradientColorCache setObject:finalColor forKey:cacheKey];
        }
        return finalColor;
    } @finally {
        os_unfair_lock_unlock(&_staticColorCreationLock);
    }

    return [UIColor whiteColor];
}

+ (CALayer *)layerFromSchemeHexString:(NSString *)hexString frame:(CGRect)frame {
    if (!hexString || hexString.length == 0 || CGRectIsEmpty(frame)) {
        return nil;
    }

    NSString *trimmedHexString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowercaseHexString = [trimmedHexString lowercaseString];

    // 处理动态颜色方案，直接生成 CALayer
    if ([lowercaseHexString isEqualToString:@"random"] || [lowercaseHexString isEqualToString:@"#random"]) {
        CALayer *layer = [CALayer layer];
        layer.frame = frame;
        layer.backgroundColor = [self _randomColor].CGColor;
        return layer;
    }
    if ([lowercaseHexString isEqualToString:@"rainbow_rotating"] || [lowercaseHexString isEqualToString:@"#rainbow_rotating"]) {
        CAGradientLayer *gradientLayer = [CAGradientLayer layer];
        gradientLayer.frame = frame;

        NSUInteger count = _baseRainbowColors.count;
        if (count == 0)
            return nil;
        uint_fast64_t currentRotationIndex = atomic_fetch_add(&_rainbowRotationCounter, 1) % count;     // 同样原子递增
        NSArray<UIColor *> *rotatedColors = [self _rotatedRainbowColorsForIndex:currentRotationIndex];  // 使用指定索引获取颜色数组

        NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:rotatedColors.count];
        for (UIColor *color in rotatedColors) {
            [cgColors addObject:(__bridge id)color.CGColor];
        }
        gradientLayer.colors = cgColors;
        gradientLayer.startPoint = CGPointMake(0.0, 0.5);
        gradientLayer.endPoint = CGPointMake(1.0, 0.5);
        return gradientLayer;
    }
    if ([lowercaseHexString isEqualToString:@"random_gradient"] || [lowercaseHexString isEqualToString:@"#random_gradient"]) {
        CAGradientLayer *gradientLayer = [CAGradientLayer layer];
        gradientLayer.frame = frame;

        NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:3];
        for (int i = 0; i < 3; i++) {
            [cgColors addObject:(__bridge id)[self _randomColor].CGColor];
        }
        gradientLayer.colors = cgColors;
        gradientLayer.startPoint = CGPointMake(0.0, 0.5);
        gradientLayer.endPoint = CGPointMake(1.0, 0.5);
        return gradientLayer;
    }

    // 解析静态渐变颜色数组
    NSArray<UIColor *> *gradientColors = [self _staticGradientColorsForHexString:hexString];
    if (gradientColors && gradientColors.count > 0) {
        CAGradientLayer *gradientLayer = [CAGradientLayer layer];
        gradientLayer.frame = frame;

        NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:gradientColors.count];
        for (UIColor *color in gradientColors) {
            [cgColors addObject:(__bridge id)color.CGColor];
        }
        gradientLayer.colors = cgColors;

        gradientLayer.startPoint = CGPointMake(0.0, 0.5);
        gradientLayer.endPoint = CGPointMake(1.0, 0.5);

        return gradientLayer;
    } else {  // 如果不是渐变，则尝试作为单色处理
        UIColor *singleColor = [self _colorFromHexString:trimmedHexString];
        if (singleColor) {
            CALayer *layer = [CALayer layer];
            layer.frame = frame;
            layer.backgroundColor = singleColor.CGColor;
            return layer;
        }
    }

    return nil;  // 无法解析的颜色方案
}

#pragma mark - Private Helper Methods (私有辅助方法)

/*
 * @brief 私有辅助方法：计算两个指定视图的最近公共父视图。
 * @param first 第一个视图。
 * @param second 第二个视图。
 * @return 两个视图的最近公共父视图，如果不存在则返回 nil。
 */
+ (__kindof UIView *)_nearestCommonSuperviewOfView:(UIView *)first andView:(UIView *)second {
    NSMutableSet *ancestors = [NSMutableSet set];
    UIView *view = first;
    while (view) {
        [ancestors addObject:view];
        view = view.superview;
    }

    view = second;
    while (view) {
        if ([ancestors containsObject:view]) {
            return view;
        }
        view = view.superview;
    }

    return nil;
}

/**
 * @brief 私有辅助方法：核心遍历引擎，使用 block 回调处理匹配的视图。
 * @param view 要遍历的根视图。
 * @param targetClass 要匹配的类。
 * @param block 找到匹配视图时执行的回调。返回 YES 可立即中止遍历。
 * @return 如果遍历被中止，则返回 YES。
 */
+ (BOOL)_traverseViewHierarchy:(UIView *)view forClass:(Class)targetClass usingBlock:(BOOL (^)(UIView *foundView))block {
    if (!view || !targetClass || !block) {
        return NO;
    }

    if ([view isKindOfClass:targetClass]) {
        if (block(view)) {
            return YES;
        }
    }

    for (UIView *subview in view.subviews) {
        if ([self _traverseViewHierarchy:subview forClass:targetClass usingBlock:block]) {
            return YES;
        }
    }

    return NO;
}

/**
 * @brief 私有辅助方法：解析单个十六进制颜色字符串。
 * @param hexString 十六进制颜色字符串，例如 "#FF0000", "FF0000", "#F00", "F00", "#AARRGGBB"
 * @return 解析出的 UIColor 对象。如果格式无效，返回 nil。
 */
+ (UIColor *)_colorFromHexString:(NSString *)hexString {
    NSString *colorString = [[hexString stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    CGFloat alpha = 1.0;
    unsigned int hexValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:colorString];

    BOOL scanSuccess = NO;
    if (colorString.length == 8) {  // AARRGGBB
        if ([scanner scanHexInt:&hexValue]) {
            alpha = ((hexValue & 0xFF000000) >> 24) / 255.0;
            scanSuccess = YES;
        }
    } else if (colorString.length == 6) {  // RRGGBB
        if ([scanner scanHexInt:&hexValue]) {
            scanSuccess = YES;
        }
    } else if (colorString.length == 3) {  // RGB (简写)
        NSString *r = [colorString substringWithRange:NSMakeRange(0, 1)];
        NSString *g = [colorString substringWithRange:NSMakeRange(1, 1)];
        NSString *b = [colorString substringWithRange:NSMakeRange(2, 1)];
        NSString *expandedColorString = [NSString stringWithFormat:@"%@%@%@%@%@%@", r, r, g, g, b, b];
        NSScanner *expandedScanner = [NSScanner scannerWithString:expandedColorString];
        if ([expandedScanner scanHexInt:&hexValue]) {
            scanSuccess = YES;
        }
    }
    if (!scanSuccess) {
        return nil;  // 返回 nil 表示解析失败
    }
    CGFloat red = ((hexValue & 0x00FF0000) >> 16) / 255.0;
    CGFloat green = ((hexValue & 0x0000FF00) >> 8) / 255.0;
    CGFloat blue = (hexValue & 0x000000FF) / 255.0;

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

/**
 * @brief 私有辅助方法：生成一个随机颜色。
 * @return 随机生成的 UIColor 对象。
 */
+ (UIColor *)_randomColor {
    return [UIColor colorWithRed:(CGFloat)arc4random_uniform(256) / 255.0 green:(CGFloat)arc4random_uniform(256) / 255.0 blue:(CGFloat)arc4random_uniform(256) / 255.0 alpha:1.0];
}

// 私有辅助方法：根据指定的起始索引获取旋转状态的彩虹颜色数组
+ (NSArray<UIColor *> *)_rotatedRainbowColorsForIndex:(uint_fast64_t)startIndex {
    NSUInteger count = _baseRainbowColors.count;
    if (count == 0)
        return @[];

    NSMutableArray<UIColor *> *rotatedColors = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [rotatedColors addObject:_baseRainbowColors[(startIndex + i) % count]];
    }
    return [rotatedColors copy];
}

/**
 * @brief 私有辅助方法：解析预定义或逗号分隔的渐变颜色字符串。
 * @param hexString 颜色方案字符串，例如 "rainbow" 或 "red,blue,#00FF00"
 * @return 颜色数组，如果不是静态渐变方案，返回 nil。
 */
+ (NSArray<UIColor *> *)_staticGradientColorsForHexString:(NSString *)hexString {
    NSString *trimmedHexString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowercaseHexString = [trimmedHexString lowercaseString];

    if ([lowercaseHexString isEqualToString:@"rainbow"] || [lowercaseHexString isEqualToString:@"#rainbow"]) {
        return _baseRainbowColors;
    }

    if ([trimmedHexString containsString:@","]) {
        // 处理逗号分隔的多色渐变
        NSArray *hexComponents = [trimmedHexString componentsSeparatedByString:@","];
        NSMutableArray *gradientColors = [NSMutableArray array];
        for (NSString *hex in hexComponents) {
            UIColor *color = [self _colorFromHexString:hex];
            if (color)
                [gradientColors addObject:color];
        }
        if (gradientColors.count >= 2) {  // 渐变至少要有两种颜色
            return [gradientColors copy];
        }
    }

    return nil;
}

+ (UIImage *)_imageWithGradientColors:(NSArray<UIColor *> *)colors size:(CGSize)size {
    if (!colors || colors.count < 2 || size.width <= 0 || size.height <= 0) {
        return nil;
    }

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull rendererContext) {
      CGContextRef context = rendererContext.CGContext;

      CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
      NSMutableArray *cgColors = [NSMutableArray array];
      for (UIColor *color in colors) {
          [cgColors addObject:(__bridge id)color.CGColor];
      }

      CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (CFArrayRef)cgColors, NULL);

      CGPoint startPoint = CGPointMake(0, 0);
      CGPoint endPoint = CGPointMake(size.width, 0);

      CGContextDrawLinearGradient(context, gradient, startPoint, endPoint, 0);

      CGGradientRelease(gradient);
      CGColorSpaceRelease(colorSpace);
    }];

    return image;
}

// ==== 版本比较 ====
// 逐段按数字比较版本号："1.9" < "1.10" 才是正确结果；而字符串比较会得出
// "1.9" > "1.10"（'9' 大于 '1'）。所以必须按小数点拆开、转成整数逐位比，
// 两串段数不一致时，缺的段按 0 处理。
#pragma mark - Version Utilities

+ (NSComparisonResult)compareVersion:(NSString *)lhs toVersion:(NSString *)rhs {
    if (lhs.length == 0 && rhs.length == 0) {
        return NSOrderedSame;
    }
    if (lhs.length == 0) {
        return NSOrderedAscending;
    }
    if (rhs.length == 0) {
        return NSOrderedDescending;
    }

    NSArray<NSString *> *lhsComponents = [lhs componentsSeparatedByString:@"."];
    NSArray<NSString *> *rhsComponents = [rhs componentsSeparatedByString:@"."];
    NSUInteger maxCount = MAX(lhsComponents.count, rhsComponents.count);

    for (NSUInteger idx = 0; idx < maxCount; idx++) {
        NSInteger lhsValue = (idx < lhsComponents.count) ? lhsComponents[idx].integerValue : 0;
        NSInteger rhsValue = (idx < rhsComponents.count) ? rhsComponents[idx].integerValue : 0;

        if (lhsValue < rhsValue) {
            return NSOrderedAscending;
        }
        if (lhsValue > rhsValue) {
            return NSOrderedDescending;
        }
    }

    return NSOrderedSame;
}

// ==== 调试工具 ====
// 把整个 App 的窗口/视图树（控件层级、frame、文字内容）导出成文本文件，
// 排查"插件界面没生效"时极有用。分两步：先在主线程快照（UIView 属性只能在
// 主线程读，所以即使要写文件也要先取好数据），再丢到后台线程写盘避免阻塞 UI；
// 沙盒路径不可写时回退到 Documents 目录。
#pragma mark - Debug Utilities (调试工具)

static NSString *DYYYSafeDescription(id _Nullable obj) {
    if (!obj) {
        return @"";
    }
    NSString *desc = nil;
    @try {
        desc = [obj description];
    } @catch (NSException *e) {
        return @"<desc-exception>";
    }
    if (desc.length > 200) {
        desc = [desc substringToIndex:200];
    }
    desc = [desc stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    desc = [desc stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return desc;
}

static void DYYYAppendViewTree(UIView *view, NSMutableString *buffer, NSUInteger depth) {
    if (!view || !buffer) {
        return;
    }

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) {
        [indent appendString:@"  "];
    }

    CGRect frame = view.frame;
    NSString *className = NSStringFromClass([view class]);
    NSString *accessibility = view.accessibilityLabel ?: @"";
    NSString *extra = @"";

    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text ?: @"";
        extra = [NSString stringWithFormat:@" text=\"%@\"", DYYYSafeDescription(text)];
    } else if ([view isKindOfClass:[UIButton class]]) {
        NSString *title = [((UIButton *)view) titleForState:UIControlStateNormal] ?: @"";
        extra = [NSString stringWithFormat:@" title=\"%@\"", DYYYSafeDescription(title)];
    } else if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *image = ((UIImageView *)view).image;
        if (image) {
            extra = [NSString stringWithFormat:@" image=%@x%@", @(image.size.width), @(image.size.height)];
        }
    }

    [buffer appendFormat:@"%@<%@: %p> frame={%.1f,%.1f,%.1f,%.1f} alpha=%.2f hidden=%d uie=%d tag=%ld a11y=\"%@\"%@\n", indent, className, view, frame.origin.x, frame.origin.y, frame.size.width,
                         frame.size.height, view.alpha, view.hidden, view.userInteractionEnabled, (long)view.tag, DYYYSafeDescription(accessibility), extra];

    for (UIView *subview in view.subviews) {
        DYYYAppendViewTree(subview, buffer, depth + 1);
    }
}

+ (void)dumpAllWindowsViewTreeToFile:(NSString *)filePath {
    if (filePath.length == 0) {
        return;
    }

    // 快照在主线程采集（UIView 属性只能在主线程读取）
    NSMutableString *buffer = [NSMutableString stringWithCapacity:64 * 1024];
    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    [buffer appendFormat:@"# DYYY view tree dump @ %@\n", [formatter stringFromDate:now]];

    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    [buffer appendFormat:@"# windows count = %lu\n\n", (unsigned long)windows.count];
    NSUInteger windowIndex = 0;
    for (UIWindow *window in windows) {
        [buffer appendFormat:@"==== Window[%lu] %@ keyWindow=%d level=%.1f hidden=%d alpha=%.2f ====\n", (unsigned long)windowIndex, NSStringFromClass([window class]), window.isKeyWindow,
                             (double)window.windowLevel, window.hidden, window.alpha];
        DYYYAppendViewTree(window, buffer, 0);
        [buffer appendString:@"\n"];
        windowIndex++;
    }

    NSString *targetPath = filePath;

    // 后台线程写入，避免阻塞 UI
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSError *writeError = nil;
      BOOL ok = [buffer writeToFile:targetPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
      if (!ok) {
          // sandbox 环境下 /var/mobile 可能不可写，fallback 到 Documents
          NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
          if (documents) {
              NSString *fallback = [documents stringByAppendingPathComponent:[targetPath lastPathComponent]];
              NSError *fallbackError = nil;
              BOOL fallbackOK = [buffer writeToFile:fallback atomically:YES encoding:NSUTF8StringEncoding error:&fallbackError];
              NSLog(@"[DYYY] dump view tree fallback to %@ ok=%d err=%@", fallback, fallbackOK, fallbackError);
          } else {
              NSLog(@"[DYYY] dump view tree failed: %@", writeError);
          }
      } else {
          NSLog(@"[DYYY] dump view tree to %@ size=%lu", targetPath, (unsigned long)buffer.length);
      }
    });
}

@end

// ==== 外部 C 函数 ====
// 用全局 C 函数（而非类方法）再包一层，是为了让 Logos 钩子（%hook 等 C 风格
// 上下文）或其他纯 C 代码不用发 ObjC 消息就能直接调用，例如 topView() 一行
// 拿到顶层控制器。这里的函数只是把内部实现转发给 DYYYUtils 的类方法。
#pragma mark - External C Functions (外部 C 函数)

NSString *cleanShareURL(NSString *url) {
    if (!url || url.length == 0) {
        return url;
    }

    NSRange questionMarkRange = [url rangeOfString:@"?"];

    if (questionMarkRange.location != NSNotFound) {
        return [url substringToIndex:questionMarkRange.location];
    }

    return url;
}

UIViewController *topView(void) {
    return [DYYYUtils topView];
}

UIViewController *findViewControllerOfClass(UIViewController *vc, Class targetClass) {
    if (!vc || !targetClass)
        return nil;
    return [DYYYUtils findViewControllerOfClass:targetClass inViewController:vc];
}

void applyTopBarTransparency(UIView *topBar) {
    if (!topBar)
        return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnablePure"]) {
        return;
    }

    NSString *transparentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTopBarTransparent"];
    if (transparentValue && transparentValue.length > 0) {
        CGFloat alphaValue = [transparentValue floatValue];
        if (alphaValue >= 0.0 && alphaValue <= 1.0) {
            CGFloat finalAlpha = (alphaValue < 0.011) ? 0.011 : alphaValue;

            UIColor *backgroundColor = topBar.backgroundColor;
            if (backgroundColor) {
                CGFloat r, g, b, a;
                if ([backgroundColor getRed:&r green:&g blue:&b alpha:&a]) {
                    topBar.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:finalAlpha * a];
                }
            }

            topBar.alpha = finalAlpha;
            for (UIView *subview in topBar.subviews) {
                subview.alpha = 1.0;
            }
        }
    }
}

// 把任意对象递归转成"可安全 JSON 序列化"的形式：NSData 转 Base64 字符串——
// JSON 是文本格式装不下二进制，Base64 是二进制转文本的标准编码，可逆且安全；
// NSDate 转时间戳、数组/字典递归处理、其他对象退回 description。
id DYYYJSONSafeObject(id obj) {
    if (!obj || obj == [NSNull null]) {
        return [NSNull null];
    }
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) {
        return obj;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id value in (NSArray *)obj) {
            id safeValue = DYYYJSONSafeObject(value);
            if (safeValue)
                [array addObject:safeValue];
        }
        return array;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)obj) {
            id safeValue = DYYYJSONSafeObject([(NSDictionary *)obj objectForKey:key]);
            if (safeValue)
                dict[key] = safeValue;
        }
        return dict;
    }
    if ([obj isKindOfClass:[NSData class]]) {
        return [(NSData *)obj base64EncodedStringWithOptions:0];
    }
    if ([obj isKindOfClass:[NSDate class]]) {
        return @([(NSDate *)obj timeIntervalSince1970]);
    }
    return [obj description];
}
