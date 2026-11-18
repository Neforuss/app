//
//  NFBCountryStore.h
//  NeoFreeBird (custom tweaks)
//
//  Country / region blocking in the style of X-Posed
//  (github.com/xaitax/x-account-location-device).
//
//  Data: the country list, aliases and region membership are generated from
//  X-Posed's own source by tools/xposed-sync/sync.mjs into
//  BHTwitter.bundle/xposed_sync.json. The AboutAccountQuery ID is refreshed
//  at runtime (at most once a day) from X-Posed's constants.js, so an ID
//  rotation reaches the app without a rebuild.
//
//  Lookups: one AboutAccountQuery per unseen author, paced (2 in flight,
//  350 ms apart), with X's 429 cooldown honoured and persisted, and results
//  cached on disk for 60 days (6 hours for "no location").
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue when one or more account locations arrive.
// userInfo[@"screenNames"] is an NSArray of lowercase handles.
extern NSString* const NFBCountryStoreDidUpdateNotification;

@interface NFBCountryRegion : NSObject
@property (nonatomic, copy, readonly) NSString* key;      // "europe"
@property (nonatomic, copy, readonly) NSString* name;     // "Europe"
@property (nonatomic, copy, readonly) NSString* flag;
@property (nonatomic, copy, readonly) NSArray<NSString*>* members;  // canonical country names
@end

@interface NFBCountryStore : NSObject

+ (instancetype)sharedStore;

// Canonical lowercase country names, sorted, from X-Posed's COUNTRY_LIST.
@property (nonatomic, copy, readonly) NSArray<NSString*>* countries;
@property (nonatomic, copy, readonly) NSArray<NFBCountryRegion*>* regions;
- (NSString*)flagForCountry:(NSString*)country;
- (NSString*)displayNameForKey:(NSString*)key;  // "united states" -> "United States"

// The user's selection: canonical country names and/or region keys.
@property (nonatomic, copy) NSSet<NSString*>* blockedKeys;

// Selected regions whose member countries are also blocked. A selected
// region not in this set blocks only accounts X labels with the region
// itself ("Europe"), which is X-Posed's default.
@property (nonatomic, copy) NSSet<NSString*>* regionsIncludingCountries;

// YES when the blocking toggle is on and something is selected.
@property (nonatomic, readonly) BOOL isFilterActive;

// Synchronous, cache-only answer for a timeline item:
//   NFBCountryVerdictBlocked / NFBCountryVerdictAllowed when the country is
//   known, NFBCountryVerdictUnknown when not cached yet. An unknown author is
//   queued for lookup; the update notification fires when it resolves.
typedef NS_ENUM(NSInteger, NFBCountryVerdict) {
    NFBCountryVerdictUnknown = 0,
    NFBCountryVerdictAllowed,
    NFBCountryVerdictBlocked,
};
- (NFBCountryVerdict)verdictForScreenName:(NSString*)screenName;

// Raw cached "account_based_in" value ("" = X reports none), or nil.
- (nullable NSString*)cachedLocationForScreenName:(NSString*)screenName;

// The AboutAccountQuery ID in use (bundled, or the refreshed one).
@property (nonatomic, copy, readonly) NSString* queryID;

// Fetches X-Posed's constants.js and adopts a changed QUERY_ID. Throttled to
// once per 24 h unless `force` is YES.
- (void)refreshQueryIDForce:(BOOL)force;

// Drops every cached location (used by the settings screen).
- (void)clearCache;
@property (nonatomic, readonly) NSUInteger cachedAccountCount;

@end

NS_ASSUME_NONNULL_END
