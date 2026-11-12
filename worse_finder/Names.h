//
//  Names.h
//  worse_finder
//
//  App identity helpers: LaunchServices display names, container identifiers,
//  and the MobileInstallation map.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// bundleID -> display name, from LSApplicationWorkspace. Empty if the
/// sandbox blocks it.
NSDictionary<NSString *, NSString *> *wq_ls_display_names(void);

/// bundleID -> data container path, from the same source. Usually empty.
NSDictionary<NSString *, NSString *> *wq_ls_container_paths(void);

/// Container identifier (bundle ID) for a container directory, via the
/// containermanager xattr, falling back to the metadata plist.
/// The caller must already hold a sandbox extension for the path.
NSString * _Nullable wq_container_identifier(NSString *path);

/// Contents of /var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist
/// (bundleID -> record). The caller must grant access to that directory first.
NSDictionary<NSString *, NSDictionary *> * _Nullable wq_launch_services_map(void);

/// CFBundleDisplayName / CFBundleName from <bundlePath>/Info.plist.
/// The caller must grant access to the bundle first.
NSString * _Nullable wq_bundle_display_name(NSString *bundlePath);

NS_ASSUME_NONNULL_END
