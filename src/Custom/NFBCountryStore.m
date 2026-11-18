//
//  NFBCountryStore.m
//  NeoFreeBird (custom tweaks)
//

#import "Custom/NFBCountryStore.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Custom/NFBCustomLogic.h"
#import "Custom/NFBRuntime.h"

// Provided by WebCreateTweet.x: the web session (auth_token + ct0) that
// NeoFreeBird's location labels already use for read-only web GraphQL calls.
extern NSDictionary* currentWebCredentials(void);
extern void prewarmWebCookiesIfNeeded(void);

NSString* const NFBCountryStoreDidUpdateNotification = @"NFBCountryStoreDidUpdateNotification";

static NSString* const kBlockedKeysDefault = @"nfb_blocked_country_keys";
static NSString* const kRegionMembersDefault = @"nfb_blocked_region_member_keys";
static const NSTimeInterval kForcedRefreshInterval = 60 * 60;
static NSString* const kBlockedSummaryDefault = @"nfb_blocked_countries_summary";
static NSString* const kQueryIDDefault = @"nfb_xposed_query_id";
static NSString* const kQueryIDCheckedDefault = @"nfb_xposed_query_id_checked";
static NSString* const kRateLimitDefault = @"nfb_country_rate_limit_until";

static NSString* const kXPosedConstantsURL =
    @"https://raw.githubusercontent.com/xaitax/x-account-location-device/main/extension/src/shared/constants.js";

// Public web bearer token, the same one x.com, X-Posed and LocationLabels.x
// send; it identifies the web client, not a user.
static NSString* const kWebBearer = @"Bearer "
                                    @"AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puT"
                                    @"s%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

static const NSTimeInterval kFoundTTL = 60 * 24 * 60 * 60;   // X-Posed: 60 days
static const NSTimeInterval kMissingTTL = 6 * 60 * 60;       // "no location" rechecked after 6 h
static const NSTimeInterval kRetryAfterFailure = 120;
static const NSTimeInterval kMinInterval = 0.35;
static const NSUInteger kMaxInFlight = 2;
static const NSUInteger kMaxQueue = 400;
static const NSUInteger kMaxCacheEntries = 20000;

@implementation NFBCountryRegion
- (instancetype)initWithDictionary:(NSDictionary*)dict {
    if ((self = [super init])) {
        _key = [dict[@"key"] copy] ?: @"";
        _name = [dict[@"name"] copy] ?: _key;
        _flag = [dict[@"flag"] copy] ?: @"";
        NSArray* members = dict[@"members"];
        _members = [members isKindOfClass:[NSArray class]] ? [members copy] : @[];
    }
    return self;
}
@end

@interface NFBCountryStore ()
@property (nonatomic, copy, readwrite) NSArray<NSString*>* countries;
@property (nonatomic, copy, readwrite) NSArray<NFBCountryRegion*>* regions;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* flags;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* lookup;
@property (nonatomic, copy) NSDictionary<NSString*, NSArray<NSString*>*>* regionMembers;
@property (nonatomic, copy) NSString* bundledQueryID;

// handle (lowercase) -> @{@"l": location, @"t": NSDate}
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* cache;
@property (nonatomic, strong) NSMutableOrderedSet<NSString*>* queue;
@property (nonatomic, strong) NSMutableSet<NSString*>* inFlight;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDate*>* retryAfter;
@property (nonatomic, strong) NSMutableSet<NSString*>* pendingNotify;
@property (nonatomic) NSTimeInterval lastStart;
@property (nonatomic) BOOL pumpScheduled;
@property (nonatomic) BOOL saveScheduled;
@property (nonatomic) BOOL refreshedAfterFailure;
@property (nonatomic) NSTimeInterval lastForcedRefresh;
// Cached selection: read per timeline item, so not from NSUserDefaults.
@property (nonatomic, copy) NSSet<NSString*>* cachedBlockedKeys;
@property (nonatomic, copy) NSSet<NSString*>* cachedRegionsIncludingCountries;
@property (nonatomic, copy) NSDictionary<NSString*, NSArray<NSString*>*>* activeMemberRecord;
@end

@implementation NFBCountryStore

+ (instancetype)sharedStore {
    static NFBCountryStore* store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [self new];
    });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableOrderedSet orderedSet];
        _inFlight = [NSMutableSet set];
        _retryAfter = [NSMutableDictionary dictionary];
        _pendingNotify = [NSMutableSet set];
        [self loadBundledData];
        [self loadCache];
    }
    return self;
}

#pragma mark - Bundled X-Posed data

- (void)loadBundledData {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"xposed_sync.json"];
    NSData* data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        NFBCustomLog(@"xposed_sync.json missing or invalid; country filter has no data");
        json = @{};
    }

    NSArray* countries = json[@"countries"];
    self.countries = [countries isKindOfClass:[NSArray class]] ? countries : @[];
    NSDictionary* flags = json[@"flags"];
    self.flags = [flags isKindOfClass:[NSDictionary class]] ? flags : @{};
    NSDictionary* lookup = json[@"lookup"];
    self.lookup = [lookup isKindOfClass:[NSDictionary class]] ? lookup : @{};

    NSMutableArray* regions = [NSMutableArray array];
    NSMutableDictionary* members = [NSMutableDictionary dictionary];
    for (NSDictionary* dict in json[@"regions"]) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        NFBCountryRegion* region = [[NFBCountryRegion alloc] initWithDictionary:dict];
        if (!region.key.length) continue;
        [regions addObject:region];
        members[region.key] = region.members;
    }
    self.regions = regions;
    self.regionMembers = members;

    NSString* queryID = json[@"query_id"];
    self.bundledQueryID = [queryID isKindOfClass:[NSString class]] && queryID.length
                              ? queryID
                              : @"XRqGa7EeokUU5kppkh13EA";
}

- (NSString*)flagForCountry:(NSString*)country {
    NSString* flag = self.flags[country];
    if (flag.length) return flag;
    for (NFBCountryRegion* region in self.regions) {
        if ([region.key isEqualToString:country]) return region.flag;
    }
    return @"";
}

- (NSString*)displayNameForKey:(NSString*)key {
    for (NFBCountryRegion* region in self.regions) {
        if ([region.key isEqualToString:key]) return region.name;
    }
    NSSet* minor = [NSSet setWithArray:@[@"and", @"of", @"the", @"da", @"de", @"du", @"la", @"et"]];
    NSMutableArray* words = [NSMutableArray array];
    NSArray* parts = [key componentsSeparatedByString:@" "];
    [parts enumerateObjectsUsingBlock:^(NSString* word, NSUInteger index, BOOL* stop) {
        if (word.length == 0) return;
        if (index > 0 && [minor containsObject:word]) {
            [words addObject:word];
        } else if ([word isEqualToString:@"us"] || [word isEqualToString:@"uk"]) {
            [words addObject:word.uppercaseString];
        } else {
            NSString* head = [[word substringToIndex:1] uppercaseString];
            [words addObject:[head stringByAppendingString:[word substringFromIndex:1]]];
        }
    }];
    return [words componentsJoinedByString:@" "];
}

#pragma mark - Selection

- (void)loadSelection {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSArray* blocked = [defaults arrayForKey:kBlockedKeysDefault];
    NSArray* including = [defaults arrayForKey:kRegionMembersDefault];
    self.cachedBlockedKeys = blocked ? [NSSet setWithArray:blocked] : [NSSet set];
    self.cachedRegionsIncludingCountries = including ? [NSSet setWithArray:including] : [NSSet set];

    // X-Posed's opt-in record: members only for selected regions that opted in.
    NSMutableDictionary* record = [NSMutableDictionary dictionary];
    for (NSString* region in self.cachedRegionsIncludingCountries) {
        if ([self.cachedBlockedKeys containsObject:region] && self.regionMembers[region]) {
            record[region] = self.regionMembers[region];
        }
    }
    self.activeMemberRecord = record;
}

- (NSSet<NSString*>*)blockedKeys {
    if (!self.cachedBlockedKeys) [self loadSelection];
    return self.cachedBlockedKeys;
}

- (NSSet<NSString*>*)regionsIncludingCountries {
    if (!self.cachedRegionsIncludingCountries) [self loadSelection];
    return self.cachedRegionsIncludingCountries;
}

- (void)setRegionsIncludingCountries:(NSSet<NSString*>*)regions {
    [[NSUserDefaults standardUserDefaults] setObject:[regions.allObjects sortedArrayUsingSelector:@selector(compare:)]
                                              forKey:kRegionMembersDefault];
    [self loadSelection];
    [[NSNotificationCenter defaultCenter] postNotificationName:NFBCountryStoreDidUpdateNotification
                                                        object:self
                                                      userInfo:@{@"screenNames": @[]}];
}

- (void)setBlockedKeys:(NSSet<NSString*>*)blockedKeys {
    NSArray* sorted = [blockedKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:sorted forKey:kBlockedKeysDefault];
    [self loadSelection];

    // The settings row shows this as its subtitle (prefKeyForSubtitle).
    NSString* summary = nil;
    if (sorted.count == 0) {
        summary = [[BHTBundle sharedBundle] localizedStringForKey:@"BLOCKED_COUNTRIES_NONE"];
    } else if (sorted.count <= 2) {
        NSMutableArray* names = [NSMutableArray array];
        for (NSString* key in sorted) [names addObject:[self displayNameForKey:key]];
        summary = [names componentsJoinedByString:@", "];
    } else {
        summary = [NSString stringWithFormat:[[BHTBundle sharedBundle] localizedStringForKey:@"BLOCKED_COUNTRIES_COUNT"],
                                             (unsigned long)sorted.count];
    }
    [defaults setObject:summary forKey:kBlockedSummaryDefault];

    [[NSNotificationCenter defaultCenter] postNotificationName:NFBCountryStoreDidUpdateNotification
                                                        object:self
                                                      userInfo:@{@"screenNames": @[]}];
}

- (BOOL)isFilterActive {
    return [BHTSettings boolForKey:@"block_countries"] && self.blockedKeys.count > 0;
}

#pragma mark - Verdicts

- (NSString*)cachedLocationForScreenName:(NSString*)screenName {
    NSDictionary* entry = self.cache[screenName.lowercaseString];
    if (!entry) return nil;
    NSString* location = entry[@"l"];
    NSDate* stamp = entry[@"t"];
    NSTimeInterval ttl = location.length ? kFoundTTL : kMissingTTL;
    if (![stamp isKindOfClass:[NSDate class]] || -[stamp timeIntervalSinceNow] > ttl) return nil;
    return [location isKindOfClass:[NSString class]] ? location : @"";
}

- (NFBCountryVerdict)verdictForScreenName:(NSString*)screenName {
    if (screenName.length == 0) return NFBCountryVerdictAllowed;
    NSString* location = [self cachedLocationForScreenName:screenName];
    if (!location) {
        [self enqueue:screenName.lowercaseString];
        return NFBCountryVerdictUnknown;
    }
    if (!self.activeMemberRecord) [self loadSelection];
    BOOL blocked = NFBLocationIsBlocked(location, self.blockedKeys, self.activeMemberRecord, self.lookup);
    return blocked ? NFBCountryVerdictBlocked : NFBCountryVerdictAllowed;
}

#pragma mark - Disk cache

- (NSURL*)cacheURL {
    NSURL* caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"nfb_account_countries.plist"];
}

- (void)loadCache {
    NSDictionary* stored = [NSDictionary dictionaryWithContentsOfURL:[self cacheURL]];
    self.cache = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

- (NSUInteger)cachedAccountCount {
    return self.cache.count;
}

- (void)clearCache {
    [self.cache removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtURL:[self cacheURL] error:nil];
}

- (void)scheduleSave {
    if (self.saveScheduled) return;
    self.saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.saveScheduled = NO;
        if (self.cache.count > kMaxCacheEntries) {
            NSArray* oldestFirst = [self.cache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                                                                    NSDictionary* b) {
                return [(NSDate*)a[@"t"] compare:(NSDate*)b[@"t"]];
            }];
            NSUInteger excess = self.cache.count - kMaxCacheEntries;
            [self.cache removeObjectsForKeys:[oldestFirst subarrayWithRange:NSMakeRange(0, excess)]];
        }
        NSDictionary* snapshot = [self.cache copy];
        NSURL* url = [self cacheURL];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [snapshot writeToURL:url atomically:YES];
        });
    });
}

#pragma mark - Lookup queue

- (void)enqueue:(NSString*)handle {
    if (handle.length == 0 || [self.inFlight containsObject:handle] || [self.queue containsObject:handle]) return;
    NSDate* retry = self.retryAfter[handle];
    if (retry && [retry timeIntervalSinceNow] > 0) return;
    if (self.queue.count >= kMaxQueue) [self.queue removeObjectAtIndex:0];  // the oldest has scrolled away
    [self.queue addObject:handle];
    [self pump];
}

- (NSDate*)rateLimitedUntil {
    NSDate* until = [[NSUserDefaults standardUserDefaults] objectForKey:kRateLimitDefault];
    return [until isKindOfClass:[NSDate class]] && [until timeIntervalSinceNow] > 0 ? until : nil;
}

- (void)schedulePumpAfter:(NSTimeInterval)delay {
    if (self.pumpScheduled) return;
    self.pumpScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       self.pumpScheduled = NO;
                       [self pump];
                   });
}

- (void)pump {
    if (self.queue.count == 0 || self.inFlight.count >= kMaxInFlight) return;

    NSDate* limited = [self rateLimitedUntil];
    if (limited) {
        [self schedulePumpAfter:[limited timeIntervalSinceNow] + 1];
        return;
    }

    NSTimeInterval wait = kMinInterval - ([NSDate timeIntervalSinceReferenceDate] - self.lastStart);
    if (wait > 0) {
        [self schedulePumpAfter:wait];
        return;
    }

    // Newest first: what was just scrolled into view matters most.
    NSString* handle = self.queue.lastObject;
    [self.queue removeObjectAtIndex:self.queue.count - 1];
    [self.inFlight addObject:handle];
    self.lastStart = [NSDate timeIntervalSinceReferenceDate];
    [self fetchHandle:handle];

    if (self.queue.count) [self schedulePumpAfter:kMinInterval];
}

- (NSString*)queryID {
    NSString* refreshed = [[NSUserDefaults standardUserDefaults] stringForKey:kQueryIDDefault];
    return refreshed.length ? refreshed : self.bundledQueryID;
}

- (NSMutableURLRequest*)requestForHandle:(NSString*)handle {
    NSDictionary* credentials = currentWebCredentials();
    NSString* authToken = credentials[@"auth_token"];
    NSString* ct0 = credentials[@"ct0"];
    if (authToken.length == 0 || ct0.length == 0) return nil;

    NSData* variablesData = [NSJSONSerialization dataWithJSONObject:@{@"screenName": handle} options:0 error:nil];
    NSString* variables = [[[NSString alloc] initWithData:variablesData encoding:NSUTF8StringEncoding]
        stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    NSString* urlString = [NSString stringWithFormat:@"https://x.com/i/api/graphql/%@/AboutAccountQuery?variables=%@",
                                                     self.queryID, variables];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 10;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:kWebBearer forHTTPHeaderField:@"authorization"];
    [request setValue:@"OAuth2Session" forHTTPHeaderField:@"x-twitter-auth-type"];
    [request setValue:@"yes" forHTTPHeaderField:@"x-twitter-active-user"];
    [request setValue:@"en" forHTTPHeaderField:@"x-twitter-client-language"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"accept-language"];  // English country names
    [request setValue:ct0 forHTTPHeaderField:@"x-csrf-token"];
    [request setValue:[NSString stringWithFormat:@"auth_token=%@; ct0=%@", authToken, ct0] forHTTPHeaderField:@"Cookie"];
    return request;
}

- (void)fetchHandle:(NSString*)handle {
    NSMutableURLRequest* request = [self requestForHandle:handle];
    if (!request) {
        // No web session yet: ask WebCreateTweet.x to establish one, and retry
        // this handle later rather than hammering.
        prewarmWebCookiesIfNeeded();
        [self finishHandle:handle location:nil retryIn:kRetryAfterFailure];
        return;
    }

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
              NSHTTPURLResponse* http =
                  [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
              NSInteger status = http.statusCode;
              dispatch_async(dispatch_get_main_queue(), ^{
                  if (status == 429) {
                      NSDate* until = NFBRateLimitResetDate(http.allHeaderFields, [NSDate date]);
                      [[NSUserDefaults standardUserDefaults] setObject:until forKey:kRateLimitDefault];
                      NFBCustomLog(@"country lookups rate-limited until %@", until);
                      [self.inFlight removeObject:handle];
                      [self.queue addObject:handle];  // try again after the cooldown
                      [self pump];
                      return;
                  }

                  NSDictionary* json = nil;
                  if (!error && status == 200 && data) {
                      json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                  }
                  if (![json isKindOfClass:[NSDictionary class]]) json = nil;

                  // The user result node, when X answered for this account.
                  id node = json;
                  for (NSString* key in @[@"data", @"user_result_by_screen_name", @"result"]) {
                      node = [node isKindOfClass:[NSDictionary class]] ? node[key] : nil;
                  }
                  NSDictionary* result = [node isKindOfClass:[NSDictionary class]] ? node : nil;
                  id errors = json[@"errors"];
                  BOOL graphQLError = [errors isKindOfClass:[NSArray class]] && [(NSArray*)errors count] > 0;

                  // No result plus an HTTP error or a GraphQL error is a
                  // failed lookup (often a rotated query ID), never "no
                  // location": that would hide nothing for 6 hours.
                  if (!result && (!json || graphQLError)) {
                      if (status == 400 || status == 404 || graphQLError) [self recoverQueryIDAfterFailure];
                      [self finishHandle:handle location:nil retryIn:kRetryAfterFailure];
                      return;
                  }

                  // Suspended or missing accounts null out whole branches.
                  id about = result[@"about_profile"];
                  id basedIn = [about isKindOfClass:[NSDictionary class]] ? about[@"account_based_in"] : nil;
                  NSString* location = [basedIn isKindOfClass:[NSString class]] ? basedIn : @"";
                  [self finishHandle:handle location:location retryIn:0];
              });
          }] resume];
}

// `location` nil = lookup failed (retry later); @"" = X reports no location.
- (void)finishHandle:(NSString*)handle location:(NSString*)location retryIn:(NSTimeInterval)retry {
    [self.inFlight removeObject:handle];
    if (location) {
        self.cache[handle] = @{@"l": location, @"t": [NSDate date]};
        [self.retryAfter removeObjectForKey:handle];
        [self scheduleSave];
        [self notifyHandle:handle];
    } else if (retry > 0) {
        self.retryAfter[handle] = [NSDate dateWithTimeIntervalSinceNow:retry];
    }
    [self pump];
}

// Coalesces arrivals so a burst of lookups re-filters the timeline once.
- (void)notifyHandle:(NSString*)handle {
    BOOL first = self.pendingNotify.count == 0;
    [self.pendingNotify addObject:handle];
    if (!first) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray* handles = self.pendingNotify.allObjects;
        [self.pendingNotify removeAllObjects];
        [[NSNotificationCenter defaultCenter] postNotificationName:NFBCountryStoreDidUpdateNotification
                                                            object:self
                                                          userInfo:@{@"screenNames": handles}];
    });
}

#pragma mark - X-Posed query ID sync

// After a failed lookup: re-fetch X-Posed's query ID, at most once an hour
// and once per ID. If X rotated the ID before X-Posed did, this stays quiet
// instead of hitting GitHub on every failed lookup.
- (void)recoverQueryIDAfterFailure {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.refreshedAfterFailure || now - self.lastForcedRefresh < kForcedRefreshInterval) return;
    self.refreshedAfterFailure = YES;
    self.lastForcedRefresh = now;
    [self refreshQueryIDForce:YES];
}

- (void)refreshQueryIDForce:(BOOL)force {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSDate* checked = [defaults objectForKey:kQueryIDCheckedDefault];
    if (!force && [checked isKindOfClass:[NSDate class]] && -[checked timeIntervalSinceNow] < 24 * 60 * 60) return;
    [defaults setObject:[NSDate date] forKey:kQueryIDCheckedDefault];

    NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:kXPosedConstantsURL]
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:15];
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
              NSString* source = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
              NSString* queryID = NFBExtractXPosedQueryID(source);
              if (!queryID) return;
              dispatch_async(dispatch_get_main_queue(), ^{
                  // Only a new ID re-arms failure recovery; the same ID again
                  // means X-Posed has not caught up yet.
                  if (![queryID isEqualToString:self.queryID]) {
                      NFBCustomLog(@"X-Posed query ID changed: %@ -> %@", self.queryID, queryID);
                      self.refreshedAfterFailure = NO;
                  }
                  [defaults setObject:queryID forKey:kQueryIDDefault];
              });
          }] resume];
}

@end
