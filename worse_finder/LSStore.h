//
//  LSStore.h
//  worse_finder
//
//  Reads lsd's CSStore2 database ("bdsl") and returns the data container ->
//  bundle ID map. Layout knowledge from WQ Files (GPL-3.0), which reverse
//  engineered the record sizes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the file starts with the LaunchServices store magic and is
/// plausibly a database.
BOOL wq_ls_store_candidate(NSString *path);

/// @{ @"containers": @{ path: bundleID }, @"names": @{ bundleID: name },
///    @"layout": label }  or nil when nothing parsed.
NSDictionary<NSString *, id> * _Nullable wq_ls_parse_store(NSString *path);

NS_ASSUME_NONNULL_END
