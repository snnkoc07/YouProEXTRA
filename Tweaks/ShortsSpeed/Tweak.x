#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface YTPlayerViewController : UIViewController
- (float)playbackRate;
- (void)didActivateVideo:(id)video;
- (void)currentVideoTimeDidChange:(id)time;
@end

@interface YTReelPlaybackViewController : UIViewController
@end

@interface YTReelPlayerViewController : UIViewController
@end

@interface YTShortsPlayerViewController : UIViewController
@end

@interface YTReelWatchRootViewController : UIViewController
@end

@interface YTPDownloader : NSObject
- (void)downloadDidFinish:(id)task fileName:(NSString *)fileName;
- (void)downloadDidFailureWithError:(NSError *)error;
- (void)startDownloadFor:(id)arg1 fileName:(NSString *)fileName text:(id)arg3;
- (void)updateProgressForID:(NSString *)recordID received:(int64_t)received total:(int64_t)total;
@end

#pragma mark - Shorts Speed (1.75x)

static const float kTargetShortsSpeed = 1.75f;

static BOOL IsShortsController(id controller) {
    if (!controller) return NO;
    id current = controller;
    for (int i = 0; current && i < 6; i++) {
        NSString *className = NSStringFromClass(object_getClass(current));
        if ([className containsString:@"Reel"] || [className containsString:@"Shorts"]) {
            return YES;
        }
        SEL parentSel = NSSelectorFromString(@"parentViewController");
        if ([current respondsToSelector:parentSel]) {
            current = ((id (*)(id, SEL))objc_msgSend)(current, parentSel);
        } else {
            break;
        }
    }
    return NO;
}

static BOOL ApplyRateToObject(id target, float rate) {
    if (!target) return NO;
    SEL setPlaybackRateSel = NSSelectorFromString(@"setPlaybackRate:");
    if ([target respondsToSelector:setPlaybackRateSel]) {
        ((void (*)(id, SEL, float))objc_msgSend)(target, setPlaybackRateSel, rate);
        return YES;
    }
    SEL setRateSel = NSSelectorFromString(@"setRate:");
    if ([target respondsToSelector:setRateSel]) {
        ((void (*)(id, SEL, float))objc_msgSend)(target, setRateSel, rate);
        return YES;
    }
    return NO;
}

static AVPlayer *FindPlayerInLayer(CALayer *layer) {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *p = ((AVPlayerLayer *)layer).player;
        if (p) return p;
    }
    for (CALayer *sub in layer.sublayers) {
        AVPlayer *p = FindPlayerInLayer(sub);
        if (p) return p;
    }
    return nil;
}

static BOOL SetRateOnHierarchy(id obj, float rate, int depth) {
    if (!obj || depth > 4) return NO;
    BOOL ok = ApplyRateToObject(obj, rate);

    SEL subviewsSel = NSSelectorFromString(@"subviews");
    if ([obj respondsToSelector:subviewsSel]) {
        NSArray *subviews = ((NSArray *(*)(id, SEL))objc_msgSend)(obj, subviewsSel);
        for (id sub in subviews) {
            ok = SetRateOnHierarchy(sub, rate, depth + 1) || ok;
        }
    }

    SEL layerSel = NSSelectorFromString(@"layer");
    if ([obj respondsToSelector:layerSel]) {
        CALayer *layer = ((CALayer *(*)(id, SEL))objc_msgSend)(obj, layerSel);
        AVPlayer *player = FindPlayerInLayer(layer);
        if (player) {
            player.rate = rate;
            ok = YES;
        }
    }

    const char *props[] = {
        "player", "_player", "playbackController", "_playbackController",
        "activePlayer", "_activePlayer", "videoPlayer", "_videoPlayer",
        "playerView", "_playerView", "playerLayer", "_playerLayer",
        "playerViewController", "_playerViewController"
    };
    for (size_t i = 0; i < sizeof(props) / sizeof(props[0]); i++) {
        SEL sel = sel_registerName(props[i]);
        if ([obj respondsToSelector:sel]) {
            id prop = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (prop && prop != obj) {
                if (ApplyRateToObject(prop, rate)) ok = YES;
                SEL pSel = NSSelectorFromString(@"player");
                if ([prop respondsToSelector:pSel]) {
                    id inner = ((id (*)(id, SEL))objc_msgSend)(prop, pSel);
                    if (ApplyRateToObject(inner, rate)) ok = YES;
                }
            }
        }
    }
    return ok;
}

static void PrimeSpeedForShorts(id controller) {
    if (!controller) return;
    SetRateOnHierarchy(controller, kTargetShortsSpeed, 0);

    SEL viewSel = NSSelectorFromString(@"view");
    if ([controller respondsToSelector:viewSel]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(controller, viewSel);
        if (view) {
            SetRateOnHierarchy(view, kTargetShortsSpeed, 0);
        }
    }
}

static void ScheduleSpeedPriming(id controller) {
    if (!controller) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PrimeSpeedForShorts(controller);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PrimeSpeedForShorts(controller);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PrimeSpeedForShorts(controller);
    });
}

#pragma mark - Download Notifications (Banner & In-App Notice)

static void RequestNotificationPermissionsIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(__unused BOOL granted, __unused NSError * _Nullable error) {}];
    });
}

static void ShowInAppNotice(NSString *message, NSTimeInterval duration) {
    if (message.length == 0) return;
    if (duration <= 0.0) duration = 2.5;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *win in scene.windows) {
                    if (win.isKeyWindow) {
                        keyWindow = win;
                        break;
                    }
                }
            }
            if (keyWindow) break;
        }
        if (!keyWindow) {
            keyWindow = UIApplication.sharedApplication.windows.firstObject;
        }
        if (!keyWindow) return;

        UIView *host = keyWindow.rootViewController.view ?: keyWindow;
        UIView *old = [host viewWithTag:0x59544C50]; // "YTLP" tag
        [old removeFromSuperview];

        UIView *banner = [UIView new];
        banner.tag = 0x59544C50;
        banner.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.95];
        banner.layer.cornerRadius = 13.0;
        banner.layer.masksToBounds = YES;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeTranslation(0.0, -16.0);

        UILabel *label = [UILabel new];
        label.text = message;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:label];

        [host addSubview:banner];
        UILayoutGuide *safe = host.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
            [banner.widthAnchor constraintGreaterThanOrEqualToConstant:180.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32.0],
            [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
            [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0],
            [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-16.0]
        ]];

        [UIView animateWithDuration:0.25 animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (banner.superview) {
                [UIView animateWithDuration:0.2 animations:^{
                    banner.alpha = 0.0;
                    banner.transform = CGAffineTransformMakeTranslation(0.0, -12.0);
                } completion:^(__unused BOOL finished) {
                    [banner removeFromSuperview];
                }];
            }
        });
    });
}

static void PostDownloadNotification(NSString *title, NSString *body, NSString *identifier) {
    RequestNotificationPermissionsIfNeeded();

    // 1. Ekranın üstünde görsel bildirim kutusu göster
    NSString *inAppText = [NSString stringWithFormat:@"%@\n%@", title, body];
    ShowInAppNotice(inAppText, 2.5);

    // 2. iOS sistem bildirim merkezine yerel bildirim gönder
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

#pragma mark - Hooks

%hook YTPlayerViewController

- (void)didActivateVideo:(id)video {
    %orig;
    id ctrl = (id)self;
    if (IsShortsController(ctrl)) {
        ScheduleSpeedPriming(ctrl);
    }
}

- (void)currentVideoTimeDidChange:(id)time {
    %orig;
    id ctrl = (id)self;
    if (IsShortsController(ctrl)) {
        SEL getter = NSSelectorFromString(@"playbackRate");
        if ([ctrl respondsToSelector:getter]) {
            float rate = ((float (*)(id, SEL))objc_msgSend)(ctrl, getter);
            if (fabs(rate - 1.0f) < 0.05f) {
                PrimeSpeedForShorts(ctrl);
            }
        }
    }
}

%end

// Reel/Shorts View Controllers
%hook YTReelPlaybackViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ScheduleSpeedPriming(self);
}
%end

%hook YTReelPlayerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ScheduleSpeedPriming(self);
}
%end

%hook YTShortsPlayerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ScheduleSpeedPriming(self);
}
%end

%hook YTReelWatchRootViewController
- (void)viewDidLayoutSubviews {
    %orig;
    ScheduleSpeedPriming(self);
}
%end

#pragma mark - Hook YTLite Download Manager

%hook YTPDownloader

- (void)downloadDidFinish:(id)task fileName:(NSString *)fileName {
    %orig;
    NSString *name = fileName ?: @"Video";
    PostDownloadNotification(@"YouTube Plus İndirme Tamamlandı",
                             [NSString stringWithFormat:@"%@ başarıyla indirildi.", name],
                             @"ytp.download.completed");
}

- (void)downloadDidFailureWithError:(NSError *)error {
    %orig;
    NSString *reason = error.localizedDescription ?: @"Bilinmeyen bir hata oluştu";
    PostDownloadNotification(@"YouTube Plus İndirme Başarısız",
                             reason,
                             @"ytp.download.failed");
}

- (void)startDownloadFor:(id)arg1 fileName:(NSString *)fileName text:(id)arg3 {
    %orig;
    NSString *name = fileName ?: @"İçerik";
    PostDownloadNotification(@"YouTube Plus İndirme Başlatıldı",
                             [NSString stringWithFormat:@"%@ indiriliyor...", name],
                             @"ytp.download.started");
}

- (void)updateProgressForID:(NSString *)recordID received:(int64_t)received total:(int64_t)total {
    %orig;
    if (total > 0) {
        int percent = (int)((received * 100) / total);
        if (percent == 25 || percent == 50 || percent == 75) {
            static int lastPercent = 0;
            if (lastPercent != percent) {
                lastPercent = percent;
                ShowInAppNotice([NSString stringWithFormat:@"İndiriliyor: %%%d", percent], 1.2);
            }
        }
    }
}

%end

%ctor {
    %init;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RequestNotificationPermissionsIfNeeded();
    });
}
