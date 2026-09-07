//
//  DYYYVersionAdapter.h
//  DYYY
//
//  版本适配表：把"逻辑角色"映射到一组候选类名，解决抖音升级/热更新改 Swift 类名
//  导致的 hook 命中失败。解析失败时打一次性"版本漂移"日志，提示该角色需要补新类名。
//
//  用法：
//    Class cls = [DYYYVersionAdapter classForRole:@"CommentInputContainer"];
//    解析不到时返回 nil，并自动打印漂移日志（告诉你"哪个角色断了、试过哪些名字"）。
//
//  维护：新增/修改候选类名只需改 DYYYVersionAdapter.m 的 DYYYAllRoles。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYVersionAdapter : NSObject

/// 按逻辑角色解析类：依次试候选精确名，失败再按 marker 扫描兜底；命中缓存。
/// 全部失败返回 nil，并"每个角色只打印一次"版本漂移日志（用于提示需补新类名）。
+ (Class)classForRole:(NSString *)role;

/// 返回该角色当前登记的候选类名数组（供漂移日志/排查用）。
+ (NSArray<NSString *> *)roleClassCandidates:(NSString *)role;

@end

NS_ASSUME_NONNULL_END
