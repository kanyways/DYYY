//
//  DYYYVersionAdapter.m
//  DYYY
//
//  版本适配表的解析实现。核心：每一个"逻辑角色"对应一组候选类名（新版本优先），
//  依次 NSClassFromString + marker 扫描兜底，命中即缓存；全失败打印一次性漂移日志，
//  指出是哪个角色断了、试过哪些名字——下次抖音更新不用翻代码，看日志就知道补什么。
//
//  存储用 ARC 管理的字典（勿用 __unsafe_unretained 结构体存数组字面量，会悬垂指针）。
//

#import "DYYYVersionAdapter.h"
#import "DYYYUtils.h"
#import <objc/runtime.h>

// 角色 -> 候选精确类名（最新版本放最前；随抖音版本改类名时在此追加/调整）。
static NSDictionary<NSString *, NSArray<NSString *> *> *DYYYRoleExactNames(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"CommentInputContainer" : @[ @"AWECommentInputViewSwiftImpl.CommentInputContainerView", @"CommentInputContainerView" ],
            @"CommentInputMiddleContainer" : @[ @"AWECommentInputViewSwiftImpl.CommentInputViewMiddleContainer", @"CommentInputViewMiddleContainer" ],
            @"CommentPanelInnerVC" : @[ @"AWECommentPanelContainerSwiftImpl.CommentContainerInnerViewController", @"AWECommentContainerViewController" ],
            // ↓ 未来抖音版本改类名时，在此追加候选名 / 新增角色即可，无需动业务代码 ↓
        };
    });
    return d;
}

// 角色 -> 兜底扫描的名字子串（精确名全失败时用；可 nil）。
static NSDictionary<NSString *, NSString *> *DYYYRoleMarker(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"CommentInputContainer" : @"CommentInputContainer",
            @"CommentInputMiddleContainer" : @"CommentInputViewMiddleContainer",
            @"CommentPanelInnerVC" : @"CommentContainerInner",
        };
    });
    return d;
}

// 角色 -> 扫描时的基类限定（可 nil）。
static NSDictionary<NSString *, NSString *> *DYYYRoleRoot(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"CommentInputContainer" : @"UIView",
            @"CommentInputMiddleContainer" : @"UIView",
            @"CommentPanelInnerVC" : @"AWEBaseListViewController",
        };
    });
    return d;
}

// 已打印过漂移日志的角色（每个角色只打一次，避免每次调用刷屏）。
static NSMutableSet<NSString *> *DYYYLoggedMissRoles(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation DYYYVersionAdapter

+ (Class)classForRole:(NSString *)role {
    if (role.length == 0) return nil;

    NSArray<NSString *> *exactNames = DYYYRoleExactNames()[role];
    if (exactNames.count == 0) return nil;

    // 精确名 + marker 扫描兜底（DYYYUtils 内部对命中做缓存）。
    Class cls = [DYYYUtils resolveClassByExactNames:exactNames
                                  containingMarker:DYYYRoleMarker()[role]
                                         underRoot:DYYYRoleRoot()[role]];
    if (cls) return cls;

    // 未命中：一次性漂移日志，提示该角色当前版本缺类，需要补新类名。
    NSMutableSet *logged = DYYYLoggedMissRoles();
    @synchronized (logged) {
        if (![logged containsObject:role]) {
            [logged addObject:role];
            NSLog(@"[DYYY] 版本漂移：角色 %@ 类未找到(候选:%@)。请配合 class-dump/nm 拿到新版类名，补进 DYYYVersionAdapter.m 的候选表。",
                  role, [self roleClassCandidates:role]);
        }
    }
    return nil;
}

+ (NSArray<NSString *> *)roleClassCandidates:(NSString *)role {
    return [DYYYRoleExactNames()[role] copy];
}

@end
