//
//  CustomTimeline.x
//  NeoFreeBird (custom tweaks)
//
//  - Country / region blocking (X-Posed parity), applied to timeline sections.
//  - Permanent topic mutes: captured from X's own topic actions, enforced on
//    GraphQL responses and on timeline sections.
//  - No infinite scroll: Home feeds lose their bottom cursor, so they end.
//
//  Runs alongside Timeline.x, which hooks the same two seams
//  (TNLResponseInfo and TFNItemsDataViewController). Logos chains the hooks;
//  each filter here only removes items, so the order between files does not
//  matter.
//

#import "Hooks/HookHelpers.h"
#import "Custom/NFBCountryStore.h"
#import "Custom/NFBCustomLogic.h"
#import "Custom/NFBMutedTopics.h"
#import "Custom/NFBRuntime.h"

#pragma mark - Model probing

// Lowercase author handle of a timeline item. For retweets X-Posed judges the
// original author (the account whose post is shown), which is what
// representedFromUser is; plain posts answer the same through fromUser.
static NSString* NFBItemScreenName(id viewModel) {
    for (NSString* userKey in @[@"representedFromUser", @"fromUser", @"author", @"user"]) {
        id user = NFBGetObject(viewModel, userKey);
        for (NSString* nameKey in @[@"username", @"screenName"]) {
            NSString* name = NFBGetObject(user, nameKey);
            if ([name isKindOfClass:[NSString class]] && name.length) return name.lowercaseString;
        }
    }
    for (NSString* nameKey in @[@"fromUserName", @"representedFromUserName"]) {
        NSString* name = NFBGetObject(viewModel, nameKey);
        if ([name isKindOfClass:[NSString class]] && name.length) {
            return [name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"@"]]
                .lowercaseString;
        }
    }
    return nil;
}

// A TFSTwitterTopic (topicID + name) reachable from `object`: the status
// banner (associatedTopic), the social context (topic), or the object itself.
static id NFBFindTopic(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;
    NSString* topicID = NFBGetObject(object, @"topicID");
    NSString* name = NFBGetObject(object, @"name");
    if ([topicID isKindOfClass:[NSString class]] && topicID.length && [name isKindOfClass:[NSString class]]) {
        return object;
    }
    for (NSString* hop in @[@"topic", @"associatedTopic", @"socialContextTopic", @"socialContext",
                            @"socialContextViewModel", @"banner", @"statusBanner", @"topicBanner", @"viewModel",
                            @"statusViewModel", @"status", @"item"]) {
        id next = NFBGetObject(object, hop);
        if (!next || next == object) continue;
        id found = NFBFindTopic(next, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Verdicts by timeline entry ID; probing every item on every section update
// would be expensive. Cleared whenever the muted list changes.
static NSCache<NSString*, NSNumber*>* NFBTopicVerdicts(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 4000;
    });
    return cache;
}

static BOOL NFBItemHasMutedTopic(id viewModel, NFBMutedTopics* muted) {
    NSString* entryID = NFBGetObject(viewModel, @"entryID");
    if (![entryID isKindOfClass:[NSString class]]) entryID = nil;
    NSNumber* cached = entryID ? [NFBTopicVerdicts() objectForKey:entryID] : nil;
    if (cached) return cached.boolValue;

    BOOL hit = NO;
    id topic = NFBFindTopic(viewModel, 0);
    if (topic) {
        NSString* topicID = NFBGetObject(topic, @"topicID");
        NSString* name = NFBGetObject(topic, @"name");
        hit = (topicID.length && [muted.mutedIDs containsObject:topicID]) ||
              (name.length && [muted.mutedLowercaseNames containsObject:name.lowercaseString]);
    }
    if (entryID) [NFBTopicVerdicts() setObject:@(hit) forKey:entryID];
    return hit;
}

static BOOL NFBIsInHierarchy(UIViewController* viewController, NSString* className) {
    Class target = NSClassFromString(className);
    UIViewController* current = viewController;
    for (NSUInteger depth = 0; target && current && depth < 32; depth++) {
        if ([current isKindOfClass:target]) return YES;
        current = current.parentViewController ?: current.navigationController ?: current.presentingViewController;
    }
    return NO;
}

static long long NFBCurrentAccountUserID(void) {
    Class hostClass = NSClassFromString(@"T1HostViewController");
    id host = hostClass && [hostClass respondsToSelector:@selector(sharedHostViewController)]
                  ? ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController))
                  : nil;
    return NFBGetInteger(NFBGetObject(host, @"currentAccount"), @"userID", 0);
}

#pragma mark - Section filtering

typedef struct {
    BOOL countries;
    BOOL topics;
} NFBFilterPlan;

static NFBFilterPlan NFBPlanForController(UIViewController* controller) {
    NFBFilterPlan plan = {NO, NO};
    // A profile is a deliberate visit: show what the user went to see.
    if (NFBIsInHierarchy(controller, @"T1ProfileViewController")) return plan;
    plan.countries = [NFBCountryStore sharedStore].isFilterActive;
    plan.topics = [NFBMutedTopics shared].isActive;
    return plan;
}

static NSArray* NFBFilterSections(UIViewController* controller, NSArray* sections) {
    NFBFilterPlan plan = NFBPlanForController(controller);
    if (!plan.countries && !plan.topics) return sections;

    NFBCountryStore* countries = [NFBCountryStore sharedStore];
    NFBMutedTopics* topics = [NFBMutedTopics shared];
    long long me = plan.countries ? NFBCurrentAccountUserID() : 0;

    BOOL modified = NO;
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:sections.count];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [result addObject:section];
            continue;
        }
        NSArray* items = section;
        NSMutableIndexSet* removed = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < items.count; i++) {
            id viewModel = unwrapDataViewItem(items[i]);
            if (plan.topics && NFBItemHasMutedTopic(viewModel, topics)) {
                [removed addIndex:i];
                continue;
            }
            if (plan.countries) {
                long long author = NFBGetInteger(NFBGetObject(viewModel, @"representedFromUser"), @"userID", 0);
                if (me != 0 && author == me) continue;  // never hide your own posts
                NSString* handle = NFBItemScreenName(viewModel);
                if (handle && [countries verdictForScreenName:handle] == NFBCountryVerdictBlocked) {
                    [removed addIndex:i];
                }
            }
        }
        if (removed.count == 0) {
            [result addObject:section];
            continue;
        }
        MarkEmptiedModuleChrome(items, removed);
        modified = YES;
        NSMutableArray* kept = [items mutableCopy];
        [kept removeObjectsAtIndexes:removed];
        if (kept.count) [result addObject:kept];
    }
    return modified ? [result copy] : sections;
}

// Last unfiltered sections per live controller, so a location that arrives
// after a post was shown can still hide it.
static NSMapTable<UIViewController*, NSArray*>* NFBLastSections(void) {
    static NSMapTable* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMapTable weakToStrongObjectsMapTable];
    });
    return table;
}

static BOOL NFBRefiltering = NO;

static void NFBRefilterControllers(NSSet<NSString*>* changedHandles) {
    NFBCountryStore* countries = [NFBCountryStore sharedStore];
    NSMapTable* table = NFBLastSections();
    for (UIViewController* controller in [[table keyEnumerator] allObjects]) {
        NSArray* sections = [table objectForKey:controller];
        if (!sections || !controller.viewIfLoaded.window) continue;

        // Only re-set sections when a post on screen actually changed state;
        // most arrivals are "allowed" and must not disturb scrolling.
        BOOL needsUpdate = changedHandles.count == 0;
        for (id section in sections) {
            if (needsUpdate || ![section isKindOfClass:[NSArray class]]) continue;
            for (id item in (NSArray*)section) {
                NSString* handle = NFBItemScreenName(unwrapDataViewItem(item));
                if (handle && [changedHandles containsObject:handle] &&
                    [countries verdictForScreenName:handle] == NFBCountryVerdictBlocked) {
                    needsUpdate = YES;
                    break;
                }
            }
        }
        SEL setSections = NSSelectorFromString(@"setSections:restoreScrollPosition:");
        if (!needsUpdate || ![controller respondsToSelector:setSections]) continue;

        NFBRefiltering = YES;
        @try {
            // Goes through the hooks above (and Timeline.x's), so every filter
            // re-runs against the unfiltered sections.
            ((void (*)(id, SEL, NSArray*, BOOL))objc_msgSend)(controller, setSections, sections, YES);
        } @catch (NSException* exception) {
            NFBCustomLog(@"refilter failed: %@", exception);
        }
        NFBRefiltering = NO;
    }
}

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    if (!NFBRefiltering && sections) [NFBLastSections() setObject:sections forKey:(UIViewController*)self];
    %orig(NFBFilterSections((UIViewController*)self, sections), restoreScrollPosition);
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    if (sections) [NFBLastSections() setObject:sections forKey:(UIViewController*)self];
    %orig(NFBFilterSections((UIViewController*)self, sections), identifiers, animation, completion);
}

%end

#pragma mark - GraphQL responses

static NSData* NFBMarker(NSString* text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL NFBDataContains(NSData* data, NSData* marker) {
    return data.length && [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

%hook TNLResponseInfo

- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                     temporarySavedFile:(id)temporarySavedFile {
    NSString* operation = NFBGraphQLOperationName(request.URL);
    if (!operation || !data.length) {
        return %orig(request, response, source, data, temporarySavedFile);
    }

    BOOL topicsOn = [BHTSettings boolForKey:@"permanent_topic_mutes"];

    // X's own "less of this topic" actions become permanent mutes.
    if (topicsOn && NFBIsTopicNegativeFeedbackOperation(operation)) {
        NSArray<NSString*>* topicIDs = NFBTopicIDsFromGraphQLRequest(request.URL, request.HTTPBody);
        NFBCustomLog(@"topic action %@ carried topic IDs %@", operation, topicIDs);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSString* topicID in topicIDs) [[NFBMutedTopics shared] muteTopicID:topicID name:nil];
        });
    }

    BOOL stripCursor = [BHTSettings boolForKey:@"disable_infinite_scroll"] && NFBIsHomeTimelineOperation(operation) &&
                       NFBDataContains(data, NFBMarker(@"cursor-bottom"));
    BOOL mentionsTopic = topicsOn && NFBDataContains(data, NFBMarker(@"topic"));
    if (!stripCursor && !mentionsTopic) {
        return %orig(request, response, source, data, temporarySavedFile);
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json) return %orig(request, response, source, data, temporarySavedFile);

    NSUInteger removed = 0;
    if (mentionsTopic) {
        NSArray* seen = NFBTopicsInJSON(json);
        if (seen.count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NFBMutedTopics shared] learnTopics:seen];
            });
        }
        NFBMutedTopics* muted = [NFBMutedTopics shared];
        if (muted.topics.count) {
            NSUInteger dropped = 0;
            json = NFBRemoveEntriesWithMutedTopics(json, muted.mutedIDs, muted.mutedLowercaseNames, &dropped);
            removed += dropped;
            if (dropped) NFBCustomLog(@"%@: removed %lu entries with muted topics", operation, (unsigned long)dropped);
        }
    }
    if (stripCursor) {
        NSUInteger dropped = 0;
        json = NFBRemoveBottomCursors(json, &dropped);
        removed += dropped;
        if (dropped) NFBCustomLog(@"%@: removed %lu bottom cursor(s), feed will end here", operation,
                                  (unsigned long)dropped);
    }

    if (removed) {
        data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] ?: data;
    }
    return %orig(request, response, source, data, temporarySavedFile);
}

%end

#pragma mark - Topic actions from the post menu

// "Not interested in this topic" / "Stop recommending" on a post. The event
// carries the status view model, whose banner or social context holds the
// topic; record it before X handles the event as usual.
static void NFBCaptureTopicFromEvent(id event, NSString* source) {
    if (![BHTSettings boolForKey:@"permanent_topic_mutes"]) return;
    id topic = NFBFindTopic(event, 0);
    NSString* topicID = NFBGetObject(topic, @"topicID");
    NSString* name = NFBGetObject(topic, @"name");
    NFBCustomLog(@"%@: topic %@ (%@)", source, name, topicID);
    if (topicID.length || name.length) [[NFBMutedTopics shared] muteTopicID:topicID name:name];
}

%group NFBTopicNotInterested
%hook T1StatusViewMarkTopicNotInterestedEventHandler
- (void)handleStatusViewEvent:(id)event controller:(id)controller scribeContext:(id)scribeContext {
    NFBCaptureTopicFromEvent(event, @"not interested");
    %orig;
}
%end
%end

%group NFBTopicStopRecommending
%hook T1StatusViewTopicStopRecommendingEventHandler
- (void)handleStatusViewEvent:(id)event controller:(id)controller scribeContext:(id)scribeContext {
    NFBCaptureTopicFromEvent(event, @"stop recommending");
    %orig;
}
%end
%end

#pragma mark - Setup

%ctor {
    %init(_ungrouped);

    SEL handle = @selector(handleStatusViewEvent:controller:scribeContext:);
    if (NFBInstancesRespond(@"T1StatusViewMarkTopicNotInterestedEventHandler", handle)) {
        %init(NFBTopicNotInterested);
    }
    if (NFBInstancesRespond(@"T1StatusViewTopicStopRecommendingEventHandler", handle)) {
        %init(NFBTopicStopRecommending);
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:NFBCountryStoreDidUpdateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* note) {
                                                      NFBRefilterControllers(
                                                          [NSSet setWithArray:note.userInfo[@"screenNames"] ?: @[]]);
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NFBMutedTopicsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* note) {
                                                      [NFBTopicVerdicts() removeAllObjects];
                                                      NFBRefilterControllers([NSSet set]);
                                                  }];

    // Keep the AboutAccountQuery ID in step with X-Posed (at most once a day).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([BHTSettings boolForKey:@"block_countries"]) [[NFBCountryStore sharedStore] refreshQueryIDForce:NO];
    });
}
