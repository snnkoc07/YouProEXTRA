#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const float kTargetShortsSpeed = 1.75f;

static BOOL ApplyPlaybackRate(id target, float rate) {
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

static void PrimeSpeedForShorts(id object) {
    if (!object) return;
    
    // Direct attempt on the object
    ApplyPlaybackRate(object, kTargetShortsSpeed);
    
    // Traverse common YouTube player properties
    NSArray *childProperties = @[
        @"playbackController",
        @"playerController",
        @"player",
        @"eventsDelegate",
        @"activeVideo"
    ];
    for (NSString *prop in childProperties) {
        SEL selector = NSSelectorFromString(prop);
        if ([object respondsToSelector:selector]) {
            id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (child && child != object) {
                ApplyPlaybackRate(child, kTargetShortsSpeed);
            }
        }
    }
}

static void ScheduleSpeedPriming(id object) {
    __weak id weakObject = object;
    for (NSNumber *delay in @[@0.0, @0.1, @0.25, @0.5, @0.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id target = weakObject;
            if (target) {
                PrimeSpeedForShorts(target);
            }
        });
    }
}

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
