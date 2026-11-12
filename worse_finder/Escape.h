//
//  Escape.h
//  worse_finder
//
//  Objective-C bridge for the worse_query sandbox escape.
//  Technique: Taj C (forcequit) and 0xjohnny, GPL-3.0,
//  https://github.com/forcequitOS/worse_query
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Every App Group listed in this process's entitlements (may be empty).
NSArray<NSString *> *wq_entitled_groups(void);

/// App Group identifier the app is actually entitled to, or nil.
NSString * _Nullable wq_app_group(void);

/// Human readable reason for the last non-zero return.
NSString * _Nullable wq_last_error(void);

/// Sandbox extension class parsed out of the last issued token, or nil.
NSString * _Nullable wq_last_extension_class(void);

/// Obtain (and consume) a sandbox extension for an arbitrary absolute path.
/// Returns a handle >= 0 on success, or one of the upstream error codes.
int64_t wq_grant(NSString *target, NSString *group, BOOL alt_flags);

/// Release a handle returned by wq_grant.
void wq_release(int64_t handle);

/// Brute-force inode -> path enumeration (the upstream `pathleak`).
/// Returns direct children of `path` whose inode is <= max_inode.
NSArray<NSString *> * _Nullable wq_pathleak(NSString *path, uint64_t max_inode);

/// Inode of a freshly created temp file, a sane upper bound for a scan.
uint64_t wq_baseline_inode(void);

NS_ASSUME_NONNULL_END
