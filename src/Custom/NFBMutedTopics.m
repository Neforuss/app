//
//  NFBMutedTopics.m
//  NeoFreeBird (custom tweaks)
//

#import "Custom/NFBMutedTopics.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"

NSString* const NFBMutedTopicsDidChangeNotification = @"NFBMutedTopicsDidChangeNotification";

static NSString* const kTopicsDefault = @"nfb_muted_topics";
static NSString* const kSummaryDefault = @"nfb_muted_topics_summary";
static NSString* const kKnownNamesDefault = @"nfb_known_topic_names";
static const NSUInteger kMaxKnownNames = 1000;

@interface NFBMutedTopics ()
@property (atomic, copy, readwrite) NSArray<NSDictionary*>* topics;
@property (atomic, copy, readwrite) NSSet<NSString*>* mutedIDs;
@property (atomic, copy, readwrite) NSSet<NSString*>* mutedLowercaseNames;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* knownNames;
@end

@implementation NFBMutedTopics

+ (instancetype)shared {
    static NFBMutedTopics* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        NSMutableArray* clean = [NSMutableArray array];
        for (id entry in [defaults arrayForKey:kTopicsDefault]) {
            if ([entry isKindOfClass:[NSDictionary class]]) [clean addObject:entry];
        }
        NSDictionary* names = [defaults dictionaryForKey:kKnownNamesDefault];
        _knownNames = names ? [names mutableCopy] : [NSMutableDictionary dictionary];
        [self adoptTopics:clean persist:NO];
    }
    return self;
}

- (BOOL)isActive {
    return [BHTSettings boolForKey:@"permanent_topic_mutes"] && self.topics.count > 0;
}

- (void)adoptTopics:(NSArray<NSDictionary*>*)topics persist:(BOOL)persist {
    self.topics = topics;
    NSMutableSet* ids = [NSMutableSet set];
    NSMutableSet* names = [NSMutableSet set];
    for (NSDictionary* topic in topics) {
        NSString* topicID = topic[@"id"];
        NSString* name = topic[@"name"];
        if ([topicID isKindOfClass:[NSString class]] && topicID.length) [ids addObject:topicID];
        if ([name isKindOfClass:[NSString class]] && name.length) [names addObject:name.lowercaseString];
    }
    self.mutedIDs = ids;
    self.mutedLowercaseNames = names;
    if (!persist) return;

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:topics forKey:kTopicsDefault];
    NSString* summary =
        topics.count == 0
            ? [[BHTBundle sharedBundle] localizedStringForKey:@"MUTED_TOPICS_NONE"]
            : [NSString stringWithFormat:[[BHTBundle sharedBundle] localizedStringForKey:@"MUTED_TOPICS_COUNT"],
                                         (unsigned long)topics.count];
    [defaults setObject:summary forKey:kSummaryDefault];
    [[NSNotificationCenter defaultCenter] postNotificationName:NFBMutedTopicsDidChangeNotification object:self];
}

- (void)muteTopicID:(NSString*)topicID name:(NSString*)name {
    NSString* cleanID = [topicID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString* cleanName = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (cleanName.length == 0 && cleanID.length) cleanName = [self knownNameForTopicID:cleanID] ?: @"";
    if (cleanID.length == 0 && cleanName.length == 0) return;

    NSMutableArray* topics = [self.topics mutableCopy];
    for (NSUInteger i = 0; i < topics.count; i++) {
        NSDictionary* existing = topics[i];
        BOOL sameID = cleanID.length && [existing[@"id"] isEqualToString:cleanID];
        BOOL sameName = cleanName.length && [[existing[@"name"] lowercaseString] isEqualToString:cleanName.lowercaseString];
        if (sameID || sameName) {
            // Already muted; fill in whichever half was missing.
            NSMutableDictionary* merged = [existing mutableCopy];
            if (![merged[@"id"] length] && cleanID.length) merged[@"id"] = cleanID;
            if (![merged[@"name"] length] && cleanName.length) merged[@"name"] = cleanName;
            if (![merged isEqualToDictionary:existing]) {
                topics[i] = merged;
                [self adoptTopics:topics persist:YES];
            }
            return;
        }
    }

    [topics insertObject:@{@"id": cleanID, @"name": cleanName, @"added": [NSDate date]} atIndex:0];
    [self adoptTopics:topics persist:YES];
}

// By value, never by row index: the list can change (a topic captured or
// named in the background) between a swipe and its action.
- (void)unmuteTopicID:(NSString*)topicID name:(NSString*)name {
    [self unmuteTopicID:topicID name:name addedWithin:-1];
}

- (void)unmuteRecentTopicID:(NSString*)topicID name:(NSString*)name within:(NSTimeInterval)seconds {
    [self unmuteTopicID:topicID name:name addedWithin:seconds];
}

// `window` < 0: any age.
- (void)unmuteTopicID:(NSString*)topicID name:(NSString*)name addedWithin:(NSTimeInterval)window {
    NSString* lowerName = name.lowercaseString;
    NSIndexSet* matches = [self.topics indexesOfObjectsPassingTest:^BOOL(NSDictionary* entry, NSUInteger i, BOOL* stop) {
        BOOL sameID = topicID.length && [entry[@"id"] isEqualToString:topicID];
        BOOL sameName = lowerName.length && [[entry[@"name"] lowercaseString] isEqualToString:lowerName];
        if (!sameID && !sameName) return NO;
        if (window < 0) return YES;
        NSDate* added = entry[@"added"];
        return [added isKindOfClass:[NSDate class]] && -[added timeIntervalSinceNow] <= window;
    }];
    if (matches.count == 0) return;
    NSMutableArray* topics = [self.topics mutableCopy];
    [topics removeObjectsAtIndexes:matches];
    [self adoptTopics:topics persist:YES];
}

- (void)learnTopics:(NSArray<NSDictionary<NSString*, NSString*>*>*)topics {
    BOOL changed = NO;
    for (NSDictionary* topic in topics) {
        NSString* topicID = topic[@"id"];
        NSString* name = topic[@"name"];
        if (!topicID.length || !name.length || [self.knownNames[topicID] isEqualToString:name]) continue;
        self.knownNames[topicID] = name;
        changed = YES;
    }
    if (!changed) return;

    if (self.knownNames.count > kMaxKnownNames) {
        NSArray* keys = self.knownNames.allKeys;
        [self.knownNames removeObjectsForKeys:[keys subarrayWithRange:NSMakeRange(0, keys.count - kMaxKnownNames)]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:self.knownNames forKey:kKnownNamesDefault];

    // Name any muted-by-ID entries that were waiting for one.
    NSMutableArray* updated = [self.topics mutableCopy];
    BOOL named = NO;
    for (NSUInteger i = 0; i < updated.count; i++) {
        NSDictionary* entry = updated[i];
        NSString* known = [entry[@"name"] length] ? nil : self.knownNames[entry[@"id"]];
        if (known.length) {
            NSMutableDictionary* copy = [entry mutableCopy];
            copy[@"name"] = known;
            updated[i] = copy;
            named = YES;
        }
    }
    if (named) [self adoptTopics:updated persist:YES];
}

- (NSString*)knownNameForTopicID:(NSString*)topicID {
    return topicID.length ? self.knownNames[topicID] : nil;
}

@end
