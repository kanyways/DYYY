# DYYY AI Agent 提示文档（入口）

> 完整原文：`AGENTS.full.md`（12 KB，按需 Read）。
> 本项目是基于 Theos/Logos 的抖音 UI 调整 Tweak，README 标注仅在**抖音 36.5.0** 测试；
> 回答需求以仓库现状为准，不要沿用旧版本描述。

## 工程关键点

- Hook 入口：`DYYY.xm`（Feed/浮窗/全局透明度/Tab Bar 高度）；`DYYYSettings.xm`（设置页
  AWESettingBaseViewController、`AWELeftSideBarWeatherLabel` 等）。
- 业务核心：`DYYYManager`（媒体下载、批量任务、Live Photo/GIF/WebP 转换、保存；`NSOperationQueue`
  与下载/回调映射）；DYYYSettingsHelper（设置依赖、入口、协议弹窗）；DYYYUtils（IP 属地、颜色、
  窗口查找、缓存路径等可复用逻辑）。
- UI：自定义视图/弹窗均 `.h/.m` 配对，在设置控制器组合。
- 数据：`CityManager`（城市映射 + GeoNames）、`DYYYConstants.h`（Keys/URL/通知名）、
  `AwemeHeaders.h`（抖音私有类/Category/宏/声明集中处）。
- 版本敏感类名统一走 `DYYYVersionAdapter classForRole:`；候选表在 `DYYYVersionAdapter.m`，
  抖音升级只改候选表。

## 职责边界（必须遵守）

- **DYYYManager（业务编排）**：下载发起/取消、批量任务、进度聚合、回调分发、相册保存、失败收敛、
  资源清理；可维护 downloadID/batchID/progress 等业务状态；可调 DYYYUtils，但不堆通用工具。
- **DYYYUtils（无状态工具）**：窗口/控制器查找、文件/缓存路径、媒体格式识别/转换、音视频合成辅助、
  颜色/文本渲染、通用提示；输入明确输出明确，不保存下载任务状态，不依赖 DYYYManager
  （单向 `DYYYManager -> DYYYUtils`）。
- 落点：任务状态机/重试/取消/批次统计/统一收尾 → Manager；可复用且无业务上下文 → Utils；
  同时包含编排+细节 → 编排留 Manager，细节下沉 Utils 新方法。
- 禁止：Utils 新增下载任务字典/批量计数器/业务开关同步；Manager 新增纯 UI 颜色算法/通用视图遍历/
  与下载保存无关的杂项工具。

## 开发规范

1. **头文件**：所有新增抖音类/方法声明写入 `AwemeHeaders.h`；Category/辅助宏也放这里；
   外部库统一经 `AwemeHeaders.h` 或对应 `.h` 引入，避免重复 import。
2. **类/函数**：业务类用 `DYYY` 前缀，拆 `.h/.m`；Logos Hook 放 `.xm`；禁止随意加全局 C 函数，
   优先扩展已有类或新建 `DYYYXXX`；用 `#pragma mark` 分区，公开方法在 `.h`。
3. **Hook**：Logos `%hook/%orig/%new`；敏感类在 `dealloc` 清理 KVO/通知（如
   `DYYYRemoveRemoteConfigObserver`）；**每个 `%new` 方法必须在 `AwemeHeaders.h` 对应类的
   `@interface` 里声明**，否则 `%hook` 内调用报 `no visible @interface ... declares the selector`；
   手势/子视图用 `objc_setAssociatedObject` 或弱引用管理生命周期；**所有 UI 写操作回主线程**
   `dispatch_async(dispatch_get_main_queue(), ^{ ... })`。
4. **设置/远程配置**：开关值来自 `NSUserDefaults`，统一用 `DYYYGetBool/DYYYGetString` 等宏或
   DYYYSettingsHelper；复杂依赖写入 `+[DYYYSettingsHelper settingsDependencyConfig]`
   （dependencies/conditionalDependencies/conflicts/mutualExclusions/valueDependencies/synchronizations）；
   远程配置/ABTest 常量统一 `DYYYConstants.h`，命名一致并注释。
5. **下载/媒体**：下载/文件系统逻辑集中 `DYYYManager`，复用单例属性；新增流程必须复用
   `finalizeDownloadWithFileURL:success:` / `finalizeDownloadWithID:success:fileURL:` 一类清理方法；
   `PHPhotoLibrary` 前必须请求授权并回主线程触发 UI（参考 `+saveMedia:mediaType:completion:`）；
   转码/合成用 `dispatch_queue_t` 或 `NSOperationQueue`，回调通知 UI。
6. **UI**：弹窗/输入/选择视图继承 `UIView` 或自定义控件，自己布局/动画，控制器/Hook 只组装；
   新设置项沿用 `AWESettingSectionModel`/`AWESettingItemModel` 的构造方式（icon/identifier/type 完整）；
   Toast/提示统一 `DYYYToast` / `DYYYBottomAlertView`，不要直接 UIAlertController。
7. **资源/缓存**：`DYYYCustomAssetsDirectory`、`NSCache` 等用 `dispatch_once` 初始化；
   新增缓存必须限制容量或提供清理；自定义图片命名遵循 `DYYYCustomIconFileNameForButtonName`。
8. **代码风格**：注释/UI 文案简体中文，文案集中对应视图或 DYYYConstants；常量用 `static const`
   或 `#define`（按是否编译期常量选择），命名与现有风格一致；clang 4 空格缩进，
   `@interface` 属性顺序 `nonatomic, strong/assign/copy`。
9. **调试**：允许 `NSLog(@"[DYYY] ...")`，发布前避免刷屏；关键路径失败用
   `DYYYToast showToast:` + log，保证用户可感知。

## 最终检查

- 新增 Hook 是否受开关保护并能恢复默认行为。
- 弱引用/通知/定时器是否释放（延时用 `AWMSafeDispatchTimer`）。
- 所有新增抖音类声明是否写入 `AwemeHeaders.h`。
- **每个 `%new` 方法是否已在 `AwemeHeaders.h` 对应类声明**。
- **版本敏感类名是否已纳入 `DYYYVersionAdapter` 候选表**，未直接 `NSClassFromString` 硬编码。
- 是否补充必要头文件 import。

## 常见工作流

1. **新增 UI Hook**：`AwemeHeaders.h` 声明目标类/属性 → `DYYY.xm`/`DYYYSettings.xm` 加 `%hook`，
   用 `NSUserDefaults` 开关控制 → UI 在 `DYYY` 前缀视图中实现并在 Hook 调用。
2. **扩展设置开关**：DYYYSettingsHelper 补依赖 key → 设置面板创建 `AWESettingItemModel`
   （identifier 与 NSUserDefaults key 对齐）→ 业务进 Manager、通用能力进 Utils。
3. **新增媒体能力**：`DYYYManager` 加实例/类方法并封装异步流程 → 通过现有下载完成/进度回调通知 UI。

## 构建与测试

```bash
make clean package                   # 本地验证（至少 make package），生成 .deb
make package INSTALL=1               # 装机验证（依赖 THEOS_DEVICE_IP；after-package 推送 dpkg -i）
make package SCHEME=rootless         # 切换 roothide/rootless
GITHUB_ACTIONS=true make package     # CI/无人值守，跳过安装，产物在 packages/
```

本地私有配置用 `Makefile.local` 覆盖 `THEOS_DEVICE_IP`，不要改主 `Makefile`。
回答涉及编译/测试的需求前，先说明是否运行上述命令及结果。

## 回复前自检

- 需求涉及的类是否已存在；若无，是否在 `AwemeHeaders.h` 与对应 `DYYY` 类中创建。
- 逻辑是否线程安全（UI→主线程，IO→后台）。
- 是否复用 DYYYUtils/DYYYSettingsHelper/`DYYYToast`，避免重复造轮子。
- 是否描述用户可见行为及开关，确保可通过设置界面操作。
