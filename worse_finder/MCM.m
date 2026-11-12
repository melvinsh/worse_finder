//
//  MCM.m
//  worse_finder
//
//  LSApplicationWorkspace enumeration is refused inside the sandbox, but
//  +applicationProxyForIdentifier: answers for any bundle ID we already know.
//

#import "MCM.h"

#import <objc/message.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>

static id ls_proxy(NSString *bundleID) {
    static Class proxyClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    });
    if (!proxyClass) return nil;
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![(id)proxyClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, selector, bundleID);
}

static id send_object(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

NSString *wq_ls_name(NSString *bundleID) {
    id proxy = ls_proxy(bundleID);
    if (!proxy) return nil;
    for (NSString *key in @[@"localizedName", @"itemName"]) {
        id value = send_object(proxy, key);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return nil;
}

NSData *wq_ls_icon(NSString *bundleID) {
    id proxy = ls_proxy(bundleID);
    if (!proxy) return nil;
    SEL selector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:selector]) return nil;
    @try {
        id data = ((id (*)(id, SEL, id))objc_msgSend)(proxy, selector, @"2x");
        if ([data isKindOfClass:[NSData class]] && [data length]) return data;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

NSDictionary<NSString *, NSString *> *wq_ls_group_containers(NSString *bundleID) {
    id proxy = ls_proxy(bundleID);
    if (!proxy) return @{};
    id groups = send_object(proxy, @"groupContainerURLs");
    if (![groups isKindOfClass:[NSDictionary class]]) return @{};

    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    [(NSDictionary *)groups enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSURL class]]) {
            paths[key] = [(NSURL *)value path];
        }
    }];
    return paths;
}

NSInteger wq_ls_application_type(NSString *bundleID) {
    id proxy = ls_proxy(bundleID);
    if (!proxy) return -1;
    id value = send_object(proxy, @"applicationType");
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : -1;
}

NSString *wq_ls_container(NSString *bundleID) {
    id proxy = ls_proxy(bundleID);
    if (!proxy) return nil;
    id url = send_object(proxy, @"dataContainerURL");
    return [url isKindOfClass:[NSURL class]] ? [url path] : nil;
}

UIImage *wq_app_icon(NSString *bundleID) {
    static SEL spiSelector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        spiSelector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:");
    });
    if ([UIImage respondsToSelector:spiSelector]) {
        @try {
            id image = ((id (*)(id, SEL, id))objc_msgSend)([UIImage class], spiSelector, bundleID);
            if ([image isKindOfClass:[UIImage class]]) return image;
        } @catch (__unused NSException *exception) {
        }
    }
    NSData *data = wq_ls_icon(bundleID);
    // Inside the sandbox LS returns a fixed 16 KB placeholder blob, not a PNG.
    if (data.length < 8) return nil;
    const uint8_t *magic = data.bytes;
    if (!(magic[0] == 0x89 && magic[1] == 0x50 && magic[2] == 0x4e && magic[3] == 0x47)) return nil;
    return [UIImage imageWithData:data];
}
