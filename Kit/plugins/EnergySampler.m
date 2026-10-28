#import "EnergySampler.h"
#import <Foundation/Foundation.h>

extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern CFTypeRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);

#if defined(__arm64__)
@interface StatsEnergyState : NSObject
@end
@implementation StatsEnergyState
@end

static CFMutableDictionaryRef channels;
static CFTypeRef subscription;

static void resetSubscription(void) {
    if (subscription) CFRelease(subscription);
    if (channels) CFRelease(channels);
    subscription = NULL;
    channels = NULL;
}
#endif

CFArrayRef StatsCopyEnergySample(void) {
#if defined(__arm64__)
    @synchronized ([StatsEnergyState class]) {
        if (!subscription) {
            CFDictionaryRef source = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
            if (!source) return NULL;
            channels = CFDictionaryCreateMutableCopy(NULL, 0, source);
            CFRelease(source);
            if (!channels) return NULL;
            CFMutableDictionaryRef subscribed = NULL;
            subscription = IOReportCreateSubscription(NULL, channels, &subscribed, 0, NULL);
            if (subscribed) CFRelease(subscribed);
            if (!subscription) { resetSubscription(); return NULL; }
        }
        CFDictionaryRef sample = IOReportCreateSamples(subscription, channels, NULL);
        if (!sample) { resetSubscription(); return NULL; }
        NSArray *items = ((__bridge NSDictionary *)sample)[@"IOReportChannels"];
        NSMutableArray *values = [NSMutableArray array];
        if ([items isKindOfClass:[NSArray class]]) {
            [items enumerateObjectsUsingBlock:^(id object, NSUInteger index, BOOL *stop) {
                if (![object isKindOfClass:[NSDictionary class]]) return;
                CFDictionaryRef item = (__bridge CFDictionaryRef)object;
                NSString *group = (__bridge NSString *)IOReportChannelGetGroup(item);
                NSString *name = (__bridge NSString *)IOReportChannelGetChannelName(item);
                NSString *unit = (__bridge NSString *)IOReportChannelGetUnitLabel(item);
                if (![group isEqualToString:@"Energy Model"] || !name || !unit) return;
                [values addObject:@{@"id": [NSString stringWithFormat:@"%lu:%@", (unsigned long)index, name],
                                    @"name": name, @"unit": unit, @"value": @(IOReportSimpleGetIntegerValue(item, 0))}];
            }];
        }
        CFRelease(sample);
        if (!values.count) { resetSubscription(); return NULL; }
        return CFBridgingRetain([values copy]);
    }
#else
    return NULL;
#endif
}
