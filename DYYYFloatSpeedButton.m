#import "DYYYFloatSpeedButton.h"
#import <UIKit/UIKit.h>
#import <float.h>
#import <math.h>
#import <objc/runtime.h>
#import "AwemeHeaders.h"
#import "DYYYFloatClearButton.h"
#import "DYYYUtils.h"

@class AWEFeedCellViewController;

FloatingSpeedButton *speedButton = nil;
BOOL dyyyCommentViewVisible = NO;
BOOL showSpeedX = NO;
CGFloat speedButtonSize = 32.0;
BOOL isFloatSpeedButtonEnabled = NO;
BOOL speedButtonForceHidden = NO;
BOOL dyyyInteractionViewVisible = NO;

static NSString *const kDYYYDefaultSpeedSettingsString = @"0.75,1.0,1.25,1.5,2.0,2.5,3.0";

static NSString *const kDYYYSpeedButtonStickToEdgeKey = @"DYYYSpeedButtonStickToEdge";
static NSString *const kDYYYSpeedButtonAutoHideKey = @"DYYYAutoHideSpeedButton";
static NSString *const kDYYYSpeedButtonAutoHideTimeKey = @"DYYYAutoHideSpeedButtonTime";

static const CGFloat kDYYYSpeedButtonEdgeInset = 10.0;
static const CGFloat kDYYYSpeedButtonDefaultYFromBottomPercent = 0.65;
static const CGFloat kDYYYSpeedButtonEdgeSwitchHysteresis = 12.0;

typedef NS_ENUM(NSInteger, DYYYSpeedButtonEdge) {
    DYYYSpeedButtonEdgeLeft = 0,
    DYYYSpeedButtonEdgeRight,
    DYYYSpeedButtonEdgeTop,
    DYYYSpeedButtonEdgeBottom,
};

static BOOL DYYYSpeedButtonStickToEdgeEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDYYYSpeedButtonStickToEdgeKey];
}

static BOOL DYYYAutoHideSpeedButtonEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDYYYSpeedButtonAutoHideKey] && DYYYSpeedButtonStickToEdgeEnabled();
}

static NSTimeInterval DYYYAutoHideSpeedButtonInterval(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDYYYSpeedButtonAutoHideTimeKey] == nil) {
        return 30.0;
    }
    double interval = [defaults doubleForKey:kDYYYSpeedButtonAutoHideTimeKey];
    return interval > 0.0 ? interval : 30.0;
}

static void DYYYApplySpeedButtonHiddenState(UIView *button, BOOL hidden) {
    if (!button) {
        return;
    }
    void (^applyBlock)(UIView *) = ^(UIView *target) {
      if (!target) {
          return;
      }
      if (target.hidden != hidden) {
          target.hidden = hidden;
      }
    };

    if ([NSThread isMainThread]) {
        applyBlock(button);
    } else {
        __weak UIView *weakButton = button;
        dispatch_async(dispatch_get_main_queue(), ^{
          applyBlock(weakButton);
        });
    }
}

static BOOL DYYYShouldHideSpeedButton(void) {
    BOOL clearModeActive = (hideButton && hideButton.isElementsHidden);
    if (clearModeActive) {
        BOOL hideSpeedInClearMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSpeed"];
        if (hideSpeedInClearMode) {
            return YES;
        }
        return speedButtonForceHidden;
    }
    if (!dyyyInteractionViewVisible) {
        return YES;
    }
    if (dyyyCommentViewVisible) {
        return YES;
    }
    if (speedButtonForceHidden) {
        return YES;
    }
    return NO;
}

static NSString *DYYYFormatSpeedOption(double speed) {
    NSString *speedString = [NSString stringWithFormat:@"%.2f", speed];
    while ([speedString containsString:@"."] && [speedString hasSuffix:@"0"]) {
        speedString = [speedString substringToIndex:speedString.length - 1];
    }
    if ([speedString hasSuffix:@"."]) {
        speedString = [speedString substringToIndex:speedString.length - 1];
    }
    return speedString;
}

static BOOL DYYYSpeedValuesMatch(double lhs, double rhs) {
    return fabs(lhs - rhs) <= 0.001;
}

NSString *DYYYDefaultSpeedSettingsString(void) {
    return kDYYYDefaultSpeedSettingsString;
}

static NSString *DYYYSpeedSettingsStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        return [[value stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return nil;
}

static NSArray<NSString *> *DYYYParsedSpeedOptionsFromString(NSString *speedConfig) {
    NSMutableArray<NSString *> *validSpeeds = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *component in [speedConfig componentsSeparatedByString:@","]) {
        NSString *trimmedValue = [component stringByTrimmingCharactersInSet:whitespace];
        if (trimmedValue.length == 0) {
            continue;
        }

        NSScanner *scanner = [NSScanner scannerWithString:trimmedValue];
        double speed = 0.0;
        if ([scanner scanDouble:&speed] && scanner.isAtEnd && isfinite(speed) && speed > 0.0) {
            [validSpeeds addObject:DYYYFormatSpeedOption(speed)];
        }
    }
    return validSpeeds;
}

static double DYYYSpeedPreferenceValue(NSString *key, double fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    double speed = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
    if (!isfinite(speed) || speed <= 0.0) {
        return fallback;
    }
    return speed;
}

static BOOL DYYYSpeedOptionsContainSpeed(NSArray<NSString *> *speedOptions, double speed) {
    if (!isfinite(speed) || speed <= 0.0) {
        return YES;
    }

    for (NSString *speedString in speedOptions) {
        if (DYYYSpeedValuesMatch([speedString doubleValue], speed)) {
            return YES;
        }
    }
    return NO;
}

static BOOL DYYYSpeedOptionsCoverRequiredPlaybackSpeeds(NSArray<NSString *> *speedOptions) {
    double defaultSpeed = DYYYSpeedPreferenceValue(@"DYYYDefaultSpeed", 1.0);
    double longPressSpeed = DYYYSpeedPreferenceValue(@"DYYYLongPressSpeed", 2.0);
    return DYYYSpeedOptionsContainSpeed(speedOptions, defaultSpeed) && DYYYSpeedOptionsContainSpeed(speedOptions, longPressSpeed);
}

BOOL DYYYNormalizeSpeedSettingsForRequiredSpeeds(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *speedConfig = DYYYSpeedSettingsStringFromValue([defaults objectForKey:@"DYYYSpeedSettings"]);
    NSArray<NSString *> *validSpeeds = DYYYParsedSpeedOptionsFromString(speedConfig ?: @"");
    BOOL shouldUseDefaultSettings = speedConfig.length == 0 || validSpeeds.count == 0 || !DYYYSpeedOptionsCoverRequiredPlaybackSpeeds(validSpeeds);

    if (!shouldUseDefaultSettings) {
        return NO;
    }

    if (![speedConfig isEqualToString:kDYYYDefaultSpeedSettingsString]) {
        [defaults setObject:kDYYYDefaultSpeedSettingsString forKey:@"DYYYSpeedSettings"];
        return YES;
    }
    return NO;
}

NSArray *getSpeedOptions() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    DYYYNormalizeSpeedSettingsForRequiredSpeeds();

    NSString *speedConfig = DYYYSpeedSettingsStringFromValue([defaults objectForKey:@"DYYYSpeedSettings"]) ?: kDYYYDefaultSpeedSettingsString;
    NSArray<NSString *> *validSpeeds = DYYYParsedSpeedOptionsFromString(speedConfig);
    if (validSpeeds.count == 0) {
        [defaults setObject:kDYYYDefaultSpeedSettingsString forKey:@"DYYYSpeedSettings"];
        validSpeeds = DYYYParsedSpeedOptionsFromString(kDYYYDefaultSpeedSettingsString);
    }

    return validSpeeds;
}

NSInteger getCurrentSpeedIndex() {
    NSInteger index = [[NSUserDefaults standardUserDefaults] integerForKey:@"DYYYCurrentSpeedIndex"];
    NSArray *speeds = getSpeedOptions();

    if (index >= speeds.count || index < 0) {
        index = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:index forKey:@"DYYYCurrentSpeedIndex"];
    }

    return index;
}

float getCurrentSpeed() {
    NSArray *speeds = getSpeedOptions();
    NSInteger index = getCurrentSpeedIndex();

    if (speeds.count == 0)
        return 1.0;
    float speed = [speeds[index] floatValue];
    return speed > 0 ? speed : 1.0;
}

void setCurrentSpeedIndex(NSInteger index) {
    NSArray *speeds = getSpeedOptions();

    if (speeds.count == 0)
        return;
    index = index % speeds.count;
    if (index < 0) {
        index += speeds.count;
    }

    [[NSUserDefaults standardUserDefaults] setInteger:index forKey:@"DYYYCurrentSpeedIndex"];
}

BOOL setCurrentSpeedValue(float speed) {
    if (!isfinite(speed) || speed <= 0.0f) {
        return NO;
    }

    NSArray *speeds = getSpeedOptions();
    for (NSInteger index = 0; index < speeds.count; index++) {
        if (DYYYSpeedValuesMatch([speeds[index] floatValue], speed)) {
            setCurrentSpeedIndex(index);
            return YES;
        }
    }
    return NO;
}

void updateSpeedButtonUI() {
    if (!speedButton)
        return;

    float currentSpeed = getCurrentSpeed();

    NSString *formattedSpeed;
    if (fmodf(currentSpeed, 1.0) == 0) {
        // 整数值 (1.0, 2.0) -> "1", "2"
        formattedSpeed = [NSString stringWithFormat:@"%.0f", currentSpeed];
    } else if (fmodf(currentSpeed * 10, 1.0) == 0) {
        // 一位小数 (1.5) -> "1.5"
        formattedSpeed = [NSString stringWithFormat:@"%.1f", currentSpeed];
    } else {
        // 两位小数 (1.25) -> "1.25"
        formattedSpeed = [NSString stringWithFormat:@"%.2f", currentSpeed];
    }

    if (showSpeedX) {
        formattedSpeed = [formattedSpeed stringByAppendingString:@"x"];
    }

    if ([NSThread isMainThread]) {
        [speedButton setTitle:formattedSpeed forState:UIControlStateNormal];
    } else {
        __weak FloatingSpeedButton *weakButton = speedButton;
        dispatch_async(dispatch_get_main_queue(), ^{
          FloatingSpeedButton *strongButton = weakButton;
          if (!strongButton) {
              return;
          }
          [strongButton setTitle:formattedSpeed forState:UIControlStateNormal];
        });
    }
}

FloatingSpeedButton *getSpeedButton(void) {
    return speedButton;
}

NSArray *findViewControllersInHierarchy(UIViewController *rootViewController) {
    if (!rootViewController) {
        return @[];
    }

    NSMutableArray *viewControllers = [NSMutableArray array];
    [viewControllers addObject:rootViewController];

    for (UIViewController *childVC in rootViewController.childViewControllers) {
        [viewControllers addObjectsFromArray:findViewControllersInHierarchy(childVC)];
    }

    return viewControllers;
}

void showSpeedButton(void) {
    speedButtonForceHidden = NO;
    updateSpeedButtonVisibility();
}

void hideSpeedButton(void) {
    speedButtonForceHidden = YES;
    updateSpeedButtonVisibility();
}

void updateSpeedButtonVisibility() {
    if (!speedButton)
        return;

    BOOL hidden = !isFloatSpeedButtonEnabled || DYYYShouldHideSpeedButton();
    if (hidden) {
        [speedButton dyyy_hideEdgeIndicator];
    } else if (speedButton.isEdgeHidden) {
        [speedButton dyyy_showEdgeIndicator];
    }
    DYYYApplySpeedButtonHiddenState(speedButton, hidden);
}

@interface FloatingSpeedButton ()
@property(nonatomic, assign) DYYYSpeedButtonEdge dyyyActiveDragEdge;
@property(nonatomic, assign) BOOL dyyyHasCenterBeforeEdgeHidden;
@property(nonatomic, assign) CGPoint dyyyCenterBeforeEdgeHidden;
- (void)dyyy_cancelAutoHideTimer;
- (void)dyyy_applyEdgeHiddenState;
- (void)dyyy_rememberCenterBeforeEdgeHidden;
- (void)dyyy_moveToNearestEdgeForHiddenState;
- (void)dyyy_restoreCenterBeforeEdgeHiddenIfNeeded;
@end

@implementation FloatingSpeedButton

+ (void)reloadConfiguration {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    isFloatSpeedButtonEnabled = [defaults boolForKey:@"DYYYEnableFloatSpeedButton"];
    showSpeedX = [defaults boolForKey:@"DYYYSpeedButtonShowX"];

    CGFloat configuredSize = [defaults floatForKey:@"DYYYSpeedButtonSize"];
    if (configuredSize <= 0.0) {
        configuredSize = 32.0;
    }
    speedButtonSize = MIN(MAX(configuredSize, 20.0), 60.0);

    void (^applyBlock)(void) = ^{
      if (speedButton && fabs(speedButton.bounds.size.width - speedButtonSize) > FLT_EPSILON) {
          speedButton.bounds = CGRectMake(0, 0, speedButtonSize, speedButtonSize);
          speedButton.layer.cornerRadius = speedButtonSize / 2.0;
          [speedButton loadSavedPosition];
      }
      updateSpeedButtonUI();
      updateSpeedButtonVisibility();
    };

    if ([NSThread isMainThread]) {
        applyBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), applyBlock);
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.accessibilityLabel = @"DYYYSpeedSwitchButton";
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.1];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;

        [self setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.3] forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:15];

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowOpacity = 0.2;

        self.userInteractionEnabled = YES;
        self.isResponding = YES;

        self.originalAlpha = 1.0;
        self.alpha = 0.5;

        [self resetFadeTimer];
        [self ensureStatusCheckTimerRunning];

        [self setupGestureRecognizers];

        [self loadSavedPosition];

        self.justToggledLock = NO;
    }
    return self;
}
- (void)setupGestureRecognizers {
    for (UIGestureRecognizer *recognizer in [self.gestureRecognizers copy]) {
        [self removeGestureRecognizer:recognizer];
    }
    [self removeTarget:self action:@selector(handleTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];
    [self removeTarget:self action:@selector(handleTouchDown:) forControlEvents:UIControlEventTouchDown];
    [self removeTarget:self action:@selector(handleTouchUpOutside:) forControlEvents:UIControlEventTouchUpOutside];

    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:panGesture];

    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPressGesture.minimumPressDuration = 0.5;
    [self addGestureRecognizer:longPressGesture];

    [self addTarget:self action:@selector(handleTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:self action:@selector(handleTouchDown:) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(handleTouchUpOutside:) forControlEvents:UIControlEventTouchUpOutside];

    panGesture.delegate = (id<UIGestureRecognizerDelegate>)self;
    longPressGesture.delegate = (id<UIGestureRecognizerDelegate>)self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }
    return NO;
}

- (void)handleTouchDown:(UIButton *)sender {
    self.isResponding = YES;
    // 倍速切换不应继承上一次点击遗留的 transform；该按钮本身没有需要保留的缩放状态。
    [UIView performWithoutAnimation:^{
      self.transform = CGAffineTransformIdentity;
    }];
    if (self.isEdgeHidden) {
        [self dyyy_restoreFromEdgeHidden];
        self.dyyyJustRestoredFromEdgeHidden = YES;
        return;
    }
    [self resetFadeTimer];
}

- (void)handleTouchUpInside:(UIButton *)sender {
    if (self.dyyyJustRestoredFromEdgeHidden) {
        self.dyyyJustRestoredFromEdgeHidden = NO;
        return;
    }
    if (self.justToggledLock) {
        self.justToggledLock = NO;
        return;
    }

    [self resetFadeTimer];

    [UIView animateWithDuration:0.08
        animations:^{
          self.transform = CGAffineTransformMakeScale(1.15, 1.15);
        }
        completion:^(BOOL finished) {
          [UIView animateWithDuration:0.08
                           animations:^{
                             self.transform = CGAffineTransformIdentity;
                           }];
        }];

    id currentController = DYYYCurrentSpeedInteractionController();
    if (currentController) {
        self.interactionController = currentController;
    }

    if (self.interactionController) {
        @try {
            [self.interactionController speedButtonTapped:self];
        } @catch (NSException *exception) {
            self.isResponding = NO;
        }
    } else {
        self.isResponding = NO;
    }
}

- (void)handleTouchUpOutside:(UIButton *)sender {
    self.justToggledLock = NO;
    [self resetFadeTimer];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    self.isResponding = YES;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (self.isEdgeHidden) {
            [self dyyy_restoreFromEdgeHidden];
        }
        [self resetFadeTimer];

        self.originalLockState = self.isLocked;

        [self toggleLockState];
    }
}

- (void)toggleLockState {
    self.isLocked = !self.isLocked;
    self.justToggledLock = YES;

    NSString *toastMessage = self.isLocked ? @"按钮已锁定" : @"按钮已解锁";
    [DYYYUtils showToast:toastMessage];

    if (self.isLocked) {
        // 锁定时先收边吸附（若开启贴边），避免锁定位置悬在屏幕中部。
        self.center = [self dyyyConstrainedCenterForProposedCenter:self.center];
        [self saveButtonPosition];
    }

    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator prepare];
        [generator impactOccurred];
    }

    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      strongSelf.justToggledLock = NO;
    });
}

- (void)resetToggleLockFlag {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      strongSelf.justToggledLock = NO;
    });
}

- (void)resetButtonState {
    BOOL preserveEdgeHidden = self.isEdgeHidden && DYYYAutoHideSpeedButtonEnabled();
    self.justToggledLock = NO;
    self.dyyyJustRestoredFromEdgeHidden = NO;
    self.isResponding = YES;
    self.userInteractionEnabled = YES;
    self.transform = CGAffineTransformIdentity;

    if (preserveEdgeHidden) {
        self.isEdgeHidden = YES;
        self.alpha = 0.02;
        [self dyyy_showEdgeIndicator];
    } else {
        self.isEdgeHidden = NO;
        [self dyyy_hideEdgeIndicator];
        self.alpha = self.originalAlpha;
        [self dyyy_schedulePresentationTimersIfNeeded];
    }

    [self setupGestureRecognizers];
}

- (void)dyyy_cancelAutoHideTimer {
    if (self.autoHideTimer) {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
    }
}

- (void)dyyy_rememberCenterBeforeEdgeHidden {
    if (self.dyyyHasCenterBeforeEdgeHidden) {
        return;
    }
    self.dyyyCenterBeforeEdgeHidden = self.center;
    self.dyyyHasCenterBeforeEdgeHidden = YES;
}

- (void)dyyy_moveToNearestEdgeForHiddenState {
    [self dyyy_rememberCenterBeforeEdgeHidden];
    self.center = [self dyyySnappedCenterForProposedCenter:self.center];
}

- (void)dyyy_restoreCenterBeforeEdgeHiddenIfNeeded {
    if (!self.dyyyHasCenterBeforeEdgeHidden) {
        return;
    }
    self.center = [self dyyyConstrainedCenterForProposedCenter:self.dyyyCenterBeforeEdgeHidden];
    self.dyyyHasCenterBeforeEdgeHidden = NO;
}

- (void)dyyy_applyEdgeHiddenState {
    // 位置锁定只限制拖动，不能阻止自动隐藏计时器收边。
    if (self.isEdgeHidden || !DYYYAutoHideSpeedButtonEnabled()) {
        return;
    }

    [self dyyy_cancelAutoHideTimer];
    [self dyyy_moveToNearestEdgeForHiddenState];
    self.isEdgeHidden = YES;
    self.alpha = 0.02;
    [self dyyy_showEdgeIndicator];
}

- (void)dyyy_restoreFromEdgeHidden {
    if (!self.isEdgeHidden) {
        return;
    }

    self.isEdgeHidden = NO;
    [self dyyy_restoreCenterBeforeEdgeHiddenIfNeeded];
    self.alpha = self.originalAlpha;
    [self dyyy_hideEdgeIndicator];
    [self resetFadeTimer];
}

- (void)dyyy_schedulePresentationTimersIfNeeded {
    if (self.isEdgeHidden) {
        self.alpha = 0.02;
        [self dyyy_showEdgeIndicator];
        return;
    }

    if (DYYYAutoHideSpeedButtonEnabled() && self.autoHideTimer && [self.autoHideTimer isValid]) {
        return;
    }

    [self resetFadeTimer];
}

- (void)dyyy_showEdgeIndicator {
    if (!self.superview || !self.isEdgeHidden) {
        return;
    }

    // 自动隐藏产生的边缘条只能依附于当前播放页；若按钮整体处于隐藏态则先收起边缘条。
    if (DYYYShouldHideSpeedButton()) {
        [self dyyy_hideEdgeIndicator];
        return;
    }

    DYYYSpeedButtonEdge edge = [self dyyyEdgeForCenter:self.center];
    CGFloat indicatorThickness = 2.0;
    CGSize superSize = self.superview.bounds.size;
    CGFloat centerX = self.center.x;
    CGFloat centerY = self.center.y;

    if (!self.edgeIndicatorView) {
        self.edgeIndicatorView = [[UIView alloc] init];
        self.edgeIndicatorView.backgroundColor = [UIColor systemGrayColor];
        self.edgeIndicatorView.userInteractionEnabled = NO;
        self.edgeIndicatorView.layer.masksToBounds = YES;
    }

    CGRect frame = CGRectZero;
    CACornerMask maskedCorners = 0;
    switch (edge) {
        case DYYYSpeedButtonEdgeLeft:
            frame = CGRectMake(0.0, centerY - CGRectGetHeight(self.bounds) * 0.5, indicatorThickness, CGRectGetHeight(self.bounds));
            maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
            break;
        case DYYYSpeedButtonEdgeRight:
            frame = CGRectMake(superSize.width - indicatorThickness, centerY - CGRectGetHeight(self.bounds) * 0.5, indicatorThickness, CGRectGetHeight(self.bounds));
            maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
            break;
        case DYYYSpeedButtonEdgeTop:
            frame = CGRectMake(centerX - CGRectGetWidth(self.bounds) * 0.5, 0.0, CGRectGetWidth(self.bounds), indicatorThickness);
            maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
            break;
        case DYYYSpeedButtonEdgeBottom:
            frame = CGRectMake(centerX - CGRectGetWidth(self.bounds) * 0.5, superSize.height - indicatorThickness, CGRectGetWidth(self.bounds), indicatorThickness);
            maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
            break;
    }

    self.edgeIndicatorView.frame = frame;
    self.edgeIndicatorView.layer.cornerRadius = indicatorThickness;
    self.edgeIndicatorView.layer.maskedCorners = maskedCorners;
    self.edgeIndicatorView.alpha = 1.0;
    self.edgeIndicatorView.hidden = NO;

    if (![self.edgeIndicatorView isDescendantOfView:self.superview]) {
        [self.superview addSubview:self.edgeIndicatorView];
    }
    [self.superview bringSubviewToFront:self.edgeIndicatorView];
}

- (void)dyyy_hideEdgeIndicator {
    if (self.edgeIndicatorView) {
        self.edgeIndicatorView.hidden = YES;
    }
}

- (void)resetFadeTimer {
    [self dyyy_cancelAutoHideTimer];
    if (self.fadeTimer) {
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
    }
    if (self.isEdgeHidden) {
        return;
    }

    if (self.alpha != self.originalAlpha) {
        [UIView animateWithDuration:0.2
                         animations:^{
                           self.alpha = self.originalAlpha;
                         }];
    }

    __weak __typeof(self) weakSelf = self;
    if (!DYYYAutoHideSpeedButtonEnabled()) {
        NSTimer *fadeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                             repeats:NO
                                                               block:^(NSTimer *timer) {
                                                                 __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                                 if (!strongSelf || strongSelf.isEdgeHidden) {
                                                                     return;
                                                                 }
                                                                 [UIView animateWithDuration:0.3
                                                                                  animations:^{
                                                                                    strongSelf.alpha = 0.5;
                                                                                  }];
                                                                 strongSelf.fadeTimer = nil;
                                                               }];
        self.fadeTimer = fadeTimer;
        [[NSRunLoop mainRunLoop] addTimer:fadeTimer forMode:NSRunLoopCommonModes];
        return;
    }

    NSTimeInterval interval = DYYYAutoHideSpeedButtonInterval();
    NSTimer *autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                             repeats:NO
                                                               block:^(NSTimer *timer) {
                                                                 __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                                 if (!strongSelf) {
                                                                     return;
                                                                 }
                                                                 [strongSelf dyyy_applyEdgeHiddenState];
                                                                 strongSelf.autoHideTimer = nil;
                                                               }];
    self.autoHideTimer = autoHideTimer;
    [[NSRunLoop mainRunLoop] addTimer:autoHideTimer forMode:NSRunLoopCommonModes];
}

- (void)dyyyEdgeGeometryForSuperviewSize:(CGSize)size
                               halfWidth:(CGFloat)hw
                              halfHeight:(CGFloat)hh
                             leftCenterX:(CGFloat *)leftCenterX
                            rightCenterX:(CGFloat *)rightCenterX
                              topCenterY:(CGFloat *)topCenterY
                           bottomCenterY:(CGFloat *)bottomCenterY
                           minAlongEdgeX:(CGFloat *)minAlongEdgeX
                           maxAlongEdgeX:(CGFloat *)maxAlongEdgeX
                           minAlongEdgeY:(CGFloat *)minAlongEdgeY
                           maxAlongEdgeY:(CGFloat *)maxAlongEdgeY {
    CGFloat inset = kDYYYSpeedButtonEdgeInset;
    *leftCenterX = hw + inset;
    *rightCenterX = size.width - hw - inset;
    *topCenterY = hh + inset;
    *bottomCenterY = size.height - hh - inset;
    *minAlongEdgeX = hw + inset;
    *maxAlongEdgeX = size.width - hw - inset;
    *minAlongEdgeY = hh + inset;
    *maxAlongEdgeY = size.height - hh - inset;
}

- (BOOL)dyyyEdgeMetricsWithLeftX:(CGFloat *)leftX
                          rightX:(CGFloat *)rightX
                            topY:(CGFloat *)topY
                         bottomY:(CGFloat *)bottomY
                            minX:(CGFloat *)minX
                            maxX:(CGFloat *)maxX
                            minY:(CGFloat *)minY
                            maxY:(CGFloat *)maxY {
    if (!self.superview) {
        return NO;
    }

    CGSize size = self.superview.bounds.size;
    CGFloat hw = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat hh = CGRectGetHeight(self.bounds) * 0.5;
    [self dyyyEdgeGeometryForSuperviewSize:size
                                 halfWidth:hw
                                halfHeight:hh
                               leftCenterX:leftX
                              rightCenterX:rightX
                                topCenterY:topY
                             bottomCenterY:bottomY
                             minAlongEdgeX:minX
                             maxAlongEdgeX:maxX
                             minAlongEdgeY:minY
                             maxAlongEdgeY:maxY];
    return YES;
}

- (CGFloat)dyyyDistanceFromPoint:(CGPoint)point toEdge:(DYYYSpeedButtonEdge)edge {
    CGFloat leftX, rightX, topY, bottomY, minX, maxX, minY, maxY;
    if (![self dyyyEdgeMetricsWithLeftX:&leftX rightX:&rightX topY:&topY bottomY:&bottomY minX:&minX maxX:&maxX minY:&minY maxY:&maxY]) {
        return CGFLOAT_MAX;
    }

    switch (edge) {
        case DYYYSpeedButtonEdgeLeft:
            return fabs(point.x - leftX);
        case DYYYSpeedButtonEdgeRight:
            return fabs(point.x - rightX);
        case DYYYSpeedButtonEdgeTop:
            return fabs(point.y - topY);
        case DYYYSpeedButtonEdgeBottom:
            return fabs(point.y - bottomY);
    }
}

- (DYYYSpeedButtonEdge)dyyyNearestEdgeForPoint:(CGPoint)point {
    DYYYSpeedButtonEdge edge = DYYYSpeedButtonEdgeLeft;
    CGFloat minDist = [self dyyyDistanceFromPoint:point toEdge:edge];

    for (DYYYSpeedButtonEdge candidate = DYYYSpeedButtonEdgeRight; candidate <= DYYYSpeedButtonEdgeBottom; candidate++) {
        CGFloat dist = [self dyyyDistanceFromPoint:point toEdge:candidate];
        if (dist < minDist) {
            minDist = dist;
            edge = candidate;
        }
    }
    return edge;
}

- (DYYYSpeedButtonEdge)dyyyEdgeForCenter:(CGPoint)center {
    return [self dyyyNearestEdgeForPoint:center];
}

- (CGPoint)dyyyCenterOnEdge:(DYYYSpeedButtonEdge)edge forPoint:(CGPoint)point {
    CGFloat leftX, rightX, topY, bottomY, minX, maxX, minY, maxY;
    if (![self dyyyEdgeMetricsWithLeftX:&leftX rightX:&rightX topY:&topY bottomY:&bottomY minX:&minX maxX:&maxX minY:&minY maxY:&maxY]) {
        return point;
    }

    switch (edge) {
        case DYYYSpeedButtonEdgeLeft:
            return CGPointMake(leftX, MIN(MAX(point.y, minY), maxY));
        case DYYYSpeedButtonEdgeRight:
            return CGPointMake(rightX, MIN(MAX(point.y, minY), maxY));
        case DYYYSpeedButtonEdgeTop:
            return CGPointMake(MIN(MAX(point.x, minX), maxX), topY);
        case DYYYSpeedButtonEdgeBottom:
            return CGPointMake(MIN(MAX(point.x, minX), maxX), bottomY);
    }
}

- (CGPoint)dyyySnappedCenterForProposedCenter:(CGPoint)proposed {
    DYYYSpeedButtonEdge edge = [self dyyyNearestEdgeForPoint:proposed];
    return [self dyyyCenterOnEdge:edge forPoint:proposed];
}

- (CGPoint)dyyyClampedCenterForProposedCenter:(CGPoint)proposed {
    CGFloat minX, maxX, minY, maxY;
    CGFloat unusedLeft, unusedRight, unusedTop, unusedBottom;
    if (![self dyyyEdgeMetricsWithLeftX:&unusedLeft rightX:&unusedRight topY:&unusedTop bottomY:&unusedBottom minX:&minX maxX:&maxX minY:&minY maxY:&maxY]) {
        return proposed;
    }
    return CGPointMake(MIN(MAX(proposed.x, minX), maxX), MIN(MAX(proposed.y, minY), maxY));
}

- (CGPoint)dyyyConstrainedCenterForProposedCenter:(CGPoint)proposed {
    if (DYYYSpeedButtonStickToEdgeEnabled()) {
        return [self dyyySnappedCenterForProposedCenter:proposed];
    }
    return [self dyyyClampedCenterForProposedCenter:proposed];
}

- (CGPoint)dyyyDefaultCenter {
    if (!self.superview) {
        return self.center;
    }

    CGSize size = self.superview.bounds.size;
    CGFloat hw = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat hh = CGRectGetHeight(self.bounds) * 0.5;
    CGFloat leftX, rightX, topY, bottomY, minX, maxX, minY, maxY;
    [self dyyyEdgeGeometryForSuperviewSize:size
                                 halfWidth:hw
                                halfHeight:hh
                               leftCenterX:&leftX
                              rightCenterX:&rightX
                                topCenterY:&topY
                             bottomCenterY:&bottomY
                             minAlongEdgeX:&minX
                             maxAlongEdgeX:&maxX
                             minAlongEdgeY:&minY
                             maxAlongEdgeY:&maxY];

    CGFloat defaultY = size.height * (1.0 - kDYYYSpeedButtonDefaultYFromBottomPercent);
    defaultY = MIN(MAX(defaultY, minY), maxY);
    return CGPointMake(rightX, defaultY);
}

- (BOOL)dyyyHasSavedPosition {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:@"DYYYSpeedButtonCenterXPercent"] != nil && [defaults objectForKey:@"DYYYSpeedButtonCenterYPercent"] != nil;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (self.isLocked)
        return;

    self.justToggledLock = NO;
    self.dyyyJustRestoredFromEdgeHidden = NO;
    if (self.isEdgeHidden) {
        [self dyyy_restoreFromEdgeHidden];
    }
    [self resetFadeTimer];

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.lastLocation = self.center;
        if (DYYYSpeedButtonStickToEdgeEnabled()) {
            self.dyyyActiveDragEdge = [self dyyyEdgeForCenter:self.center];
            self.center = [self dyyyCenterOnEdge:self.dyyyActiveDragEdge forPoint:self.center];
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (DYYYSpeedButtonStickToEdgeEnabled()) {
            CGPoint touchPoint = [pan locationInView:self.superview];
            DYYYSpeedButtonEdge nearestEdge = [self dyyyNearestEdgeForPoint:touchPoint];
            if (nearestEdge != self.dyyyActiveDragEdge) {
                CGFloat currentDist = [self dyyyDistanceFromPoint:touchPoint toEdge:self.dyyyActiveDragEdge];
                CGFloat nearestDist = [self dyyyDistanceFromPoint:touchPoint toEdge:nearestEdge];
                if (nearestDist + kDYYYSpeedButtonEdgeSwitchHysteresis < currentDist) {
                    self.dyyyActiveDragEdge = nearestEdge;
                }
            }
            self.center = [self dyyyCenterOnEdge:self.dyyyActiveDragEdge forPoint:touchPoint];
        } else {
            CGPoint translation = [pan translationInView:self.superview];
            CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
            newCenter.x = MAX(self.frame.size.width / 2, MIN(newCenter.x, self.superview.frame.size.width - self.frame.size.width / 2));
            newCenter.y = MAX(self.frame.size.height / 2, MIN(newCenter.y, self.superview.frame.size.height - self.frame.size.height / 2));

            self.center = newCenter;
            [pan setTranslation:CGPointZero inView:self.superview];
        }
        self.alpha = 0.8;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.center = [self dyyyConstrainedCenterForProposedCenter:self.center];
        self.alpha = self.originalAlpha;
        [self saveButtonPosition];
        if (self.isEdgeHidden) {
            [self dyyy_showEdgeIndicator];
        }
    }
}

- (void)saveButtonPosition {
    if (self.superview) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:self.center.x / self.superview.bounds.size.width forKey:@"DYYYSpeedButtonCenterXPercent"];
        [defaults setFloat:self.center.y / self.superview.bounds.size.height forKey:@"DYYYSpeedButtonCenterYPercent"];
        [defaults setBool:self.isLocked forKey:@"DYYYSpeedButtonLocked"];
    }
}

- (void)loadSavedPosition {
    if (!self.superview) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.isLocked = [defaults boolForKey:@"DYYYSpeedButtonLocked"];

    CGPoint targetCenter;
    if ([self dyyyHasSavedPosition]) {
        float centerXPercent = [defaults floatForKey:@"DYYYSpeedButtonCenterXPercent"];
        float centerYPercent = [defaults floatForKey:@"DYYYSpeedButtonCenterYPercent"];
        targetCenter = CGPointMake(centerXPercent * self.superview.bounds.size.width, centerYPercent * self.superview.bounds.size.height);
    } else {
        targetCenter = [self dyyyDefaultCenter];
    }

    self.center = [self dyyyConstrainedCenterForProposedCenter:targetCenter];
}

- (void)resetToDefaultPosition {
    if (!self.superview) {
        return;
    }

    self.dyyyHasCenterBeforeEdgeHidden = NO;
    if (self.isEdgeHidden) {
        [self dyyy_restoreFromEdgeHidden];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:@"DYYYSpeedButtonCenterXPercent"];
    [defaults removeObjectForKey:@"DYYYSpeedButtonCenterYPercent"];
    self.center = [self dyyyDefaultCenter];
    [self resetFadeTimer];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        [self loadSavedPosition];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopTimers];
        return;
    }
    [self ensureStatusCheckTimerRunning];
    [self dyyy_schedulePresentationTimersIfNeeded];
}

- (void)ensureStatusCheckTimerRunning {
    if (self.statusCheckTimer && [self.statusCheckTimer isValid]) {
        return;
    }
    // block 版定时器不 retain target，配合 __weak 打破
    // "self 持有 timer / timer 持有 self" 的循环引用。
    // 原 selector 版 target:self 在按钮常驻 keyWindow 时形成有界泄漏
    // （self 永不释放，dealloc 永远不执行）。
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *_Nonnull t) {
        [weakSelf checkAndRecoverButtonStatus];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.statusCheckTimer = timer;
}

- (void)stopTimers {
    if (self.statusCheckTimer) {
        [self.statusCheckTimer invalidate];
        self.statusCheckTimer = nil;
    }
    [self dyyy_cancelAutoHideTimer];
    if (self.fadeTimer) {
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
    }
}

- (void)checkAndRecoverButtonStatus {
    if (!self.isResponding) {
        [self resetButtonState];
        self.isResponding = YES;
    }

    if (!self.interactionController) {
        self.interactionController = DYYYCurrentSpeedInteractionController();
    }
}

- (void)dealloc {
    [self dyyy_hideEdgeIndicator];
    [self.edgeIndicatorView removeFromSuperview];
    [self stopTimers];
}
@end
