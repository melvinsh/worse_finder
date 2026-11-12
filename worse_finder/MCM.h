//
//  MCM.h
//  worse_finder
//
//  LaunchServices per-bundle lookups: display name, icon, container path.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Localized display name for a bundle ID, or nil.
NSString * _Nullable wq_ls_name(NSString *bundleID);

/// PNG icon data for a bundle ID, or nil.
NSData * _Nullable wq_ls_icon(NSString *bundleID);

/// Decoded app icon for a bundle ID, or nil.
UIImage * _Nullable wq_app_icon(NSString *bundleID);

/// Data container LS reports for a bundle ID, or nil.
NSString * _Nullable wq_ls_container(NSString *bundleID);

/// group identifier -> container path for one bundle ID (may be empty).
NSDictionary<NSString *, NSString *> *wq_ls_group_containers(NSString *bundleID);

/// LSApplicationProxy.applicationType: 0 user, 1 system, 2 internal, -1 unknown.
NSInteger wq_ls_application_type(NSString *bundleID);

NS_ASSUME_NONNULL_END
