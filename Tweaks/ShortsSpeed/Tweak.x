#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

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

static void PrimeSpeedForShorts(id object) {
    if (!object) return;
    
    // 1. Direct apply
    ApplyRateToObject(object, kTargetShortsSpeed);
    
    // 2. Child properties
    NSArray *childProperties = @[
        @"player",
        @"playerController",
        @"playbackController",
        @"eventsDelegate",
        @"activeVideo"
    ];
    for (NSString *prop in childProperties) {
        SEL selector = NSSelectorFromString(prop);
        if ([object respondsToSelector:selector]) {
            id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (child && child != object) {
                ApplyRateToObject(child, kTargetShortsSpeed);
            }
        }
    }
    
    // 3. Fallback: Search AVPlayerLayer in view hierarchy
    if ([object isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)object;
        if (vc.isViewLoaded) {
            AVPlayer *avPlayer = FindPlayerInLayer(vc.view.layer);
            if (avPlayer && avPlayer.rate > 0.0f) {
                avPlayer.rate = kTargetShortsSpeed;
            }
        }
    } else if ([object isKindOfClass:UIView.class]) {
        UIView *v = (UIView *)object;
        AVPlayer *avPlayer = FindPlayerInLayer(v.layer);
        if (avPlayer && avPlayer.rate > 0.0f) {
            avPlayer.rate = kTargetShortsSpeed;
        }
    }
}

static void ScheduleSpeedPriming(id object) {
    __weak id weakObject = object;
    for (NSNumber *delay in @[@0.0, @0.1, @0.25, @0.5, @0.9, @1.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id target = weakObject;
            if (target) {
                PrimeSpeedForShorts(target);
            }
        });
    }
}

// Hook core YTPlayerViewController so whenever a short activates, speed is enforced
%hook YTPlayerViewController

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    if (IsShortsController(self)) {
        ScheduleSpeedPriming(self);
    }
}

- (void)singleVideo:(id)arg1 currentVideoTimeDidChange:(id)arg2 {
    %orig;
    if (IsShortsController(self)) {
        // Enforce rate if currently 1.0x
        SEL getter = NSSelectorFromString(@"playbackRate");
        if ([self respondsToSelector:getter]) {
            float rate = ((float (*)(id, SEL))objc_msgSend)(self, getter);
            if (fabs(rate - 1.0f) < 0.05f) {
                PrimeSpeedForShorts(self);
            }
        }
    }
}

%end

// Hook Shorts View Controllers
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
