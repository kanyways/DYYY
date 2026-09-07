#import "DYYYBottomAlertView.h"
#import "AwemeHeaders.h"
#import "DYYYUtils.h"

@implementation DYYYBottomAlertView

+ (UIViewController *)showAlertWithTitle:(NSString *)title
                                 message:(NSString *)message
                               avatarURL:(nullable NSString *)avatarURL
                        cancelButtonText:(nullable NSString *)cancelButtonText
                       confirmButtonText:(nullable NSString *)confirmButtonText
                            cancelAction:(DYYYAlertActionHandler)cancelAction
                             closeAction:(nullable DYYYAlertActionHandler)closeAction
                           confirmAction:(DYYYAlertActionHandler)confirmAction {
    AFDPrivacyHalfScreenViewController *vc = [NSClassFromString(@"AFDPrivacyHalfScreenViewController") new];

    if (!vc)
        return nil;

    if (cancelButtonText.length == 0) {
        cancelButtonText = @"取消";
    }

    if (confirmButtonText.length == 0) {
        confirmButtonText = @"确定";
    }

    UIImageView *imageView = nil;
    if (avatarURL.length > 0) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [imageView.widthAnchor constraintEqualToConstant:60].active = YES;
        [imageView.heightAnchor constraintEqualToConstant:60].active = YES;
        imageView.layer.cornerRadius = 30;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.layer.masksToBounds = YES;
        imageView.clipsToBounds = YES;

        // 设置默认占位图
        imageView.image = [UIImage imageNamed:@"AppIcon60x60"];

        // 异步加载网络图片
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
          if (imageData) {
              UIImage *image = [UIImage imageWithData:imageData];
              if (image) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    imageView.image = image;
                  });
              }
          }
        });
    }

    DYYYAlertActionHandler wrappedCancelAction = ^{
      if (cancelAction)
          cancelAction();
    };

    DYYYAlertActionHandler wrappedCloseActionBlock = ^{
      if (closeAction) {
          closeAction();
      } else {
          wrappedCancelAction();
      }
    };

    DYYYAlertActionHandler wrappedConfirmAction = ^{
      if (confirmAction)
          confirmAction();
    };

    vc.closeButtonClickedBlock = wrappedCloseActionBlock;
    vc.slideDismissBlock = wrappedCloseActionBlock;
    vc.tapDismissBlock = wrappedCloseActionBlock;

    [vc configWithImageView:imageView
                     lockImage:nil
              defaultLockState:NO
                titleLabelText:title
              contentLabelText:message
          leftCancelButtonText:cancelButtonText
        rightConfirmButtonText:confirmButtonText
          rightBtnClickedBlock:wrappedConfirmAction
        leftButtonClickedBlock:wrappedCancelAction];

    if (avatarURL.length > 0) {
        [vc setCornerRadius:11];
        [vc setOnlyTopCornerClips:YES];
    } else {
        [vc setUseCardUIStyle:YES];
    }

    UIViewController *topVC = [DYYYUtils topView];
    if (!topVC || ![vc respondsToSelector:@selector(presentOnViewController:)]) {
        // 用户设备未越狱，读不到运行期日志；这里用屏幕 Toast 直观呈现失败原因，
        // 避免“无弹窗但无声无息”，便于在设备上直接判断。
        [DYYYUtils showToast:[NSString stringWithFormat:@"关注确认弹窗失败：topVC=%@ presentSel=%d",
                                                        topVC ? NSStringFromClass(topVC.class) : @"nil",
                                                        [vc respondsToSelector:@selector(presentOnViewController:)] ? 1 : 0]];
        return nil;
    }

    // 若顶控制器正处在转场中（isBeingPresented/isBeingDismissed），立即 present 可能被
    // UIKit 拒绝（"Attempt to present ... while a presentation is in progress"）。
    // 稍候在转场结束后重试；重试几次仍不行才用 Toast 兜底报告。
    __block int retries = 0;
    void (^tryPresent)(void) = ^{
        if (![topVC isBeingPresented] && ![topVC isBeingDismissed]) {
            [vc presentOnViewController:topVC];
            return;
        }
        if (++retries < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryPresent);
        } else {
            [DYYYUtils showToast:[NSString stringWithFormat:@"关注确认弹窗失败：顶栏转场中 topVC=%@",
                                                            NSStringFromClass(topVC.class)]];
        }
    };
    tryPresent();
    return vc;

    return vc;
}
@end