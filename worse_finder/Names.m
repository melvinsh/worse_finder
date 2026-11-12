//
//  Names.m
//  worse_finder
//

#import "Names.h"

#import <objc/message.h>
#include <dlfcn.h>
#include <errno.h>
#include <sys/xattr.h>

static id send_id(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static NSArray *send_array(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((NSArray * (*)(id, SEL))objc_msgSend)(object, sel);
}

static id workspace(void) {
    static id shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_NOW);
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) shared = send_id((id)cls, @"defaultWorkspace");
    });
    return shared;
}

static NSArray *installed_proxies(void) {
    static NSArray *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id ws = workspace();
        if (!ws) return;
        NSArray *apps = send_array(ws, @"allInstalledApplications");
        if (!apps) apps = send_array(ws, @"allApplications");
        if ([apps isKindOfClass:[NSArray class]]) cached = apps;
    });
    return cached;
}

NSDictionary<NSString *, NSString *> *wq_ls_display_names(void) {
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (id proxy in installed_proxies()) {
        NSString *bundleID = send_id(proxy, @"bundleIdentifier");
        NSString *name = send_id(proxy, @"localizedName");
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            name = send_id(proxy, @"itemName");
        }
        if ([bundleID isKindOfClass:[NSString class]] && bundleID.length &&
            [name isKindOfClass:[NSString class]] && name.length) {
            names[bundleID] = name;
        }
    }
    return names;
}

NSDictionary<NSString *, NSString *> *wq_ls_container_paths(void) {
    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    for (id proxy in installed_proxies()) {
        NSString *bundleID = send_id(proxy, @"bundleIdentifier");
        NSURL *url = send_id(proxy, @"dataContainerURL");
        if ([bundleID isKindOfClass:[NSString class]] && [url isKindOfClass:[NSURL class]]) {
            paths[bundleID] = url.path;
        }
    }
    return paths;
}

NSString *wq_container_identifier(NSString *path) {
    char buffer[512];
    ssize_t length = getxattr(path.fileSystemRepresentation,
                              "com.apple.containermanager.identifier",
                              buffer, sizeof(buffer) - 1, 0, 0);
    if (length > 0) {
        buffer[length] = 0;
        return [NSString stringWithUTF8String:buffer];
    }

    NSString *meta = [path stringByAppendingPathComponent:
                      @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
    NSString *identifier = plist[@"MCMMetadataIdentifier"];
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

NSDictionary<NSString *, NSDictionary *> *wq_launch_services_map(void) {
    NSString *path = @"/private/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist";
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListMutableContainers
                                                          format:NULL
                                                           error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary<NSString *, NSDictionary *> *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)plist enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSDictionary class]]) {
            result[key] = value;
        }
    }];
    return result;
}

NSString *wq_bundle_display_name(NSString *bundlePath) {
    NSString *plist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        id value = info[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}
