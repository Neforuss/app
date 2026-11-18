//
//  NFBCustomLogic.m
//  NeoFreeBird (custom tweaks)
//

#import "Custom/NFBCustomLogic.h"

#pragma mark - Small helpers

static NSString* NFBString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber*)value stringValue];
    return nil;
}

static BOOL NFBIsBlank(NSString* value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
               .length == 0;
}

#pragma mark - Copy All

NSString* NFBExpandURLsInText(NSString* text, NSArray<NSDictionary*>* urls) {
    if (text.length == 0) return text ?: @"";
    NSMutableString* result = [text mutableCopy];

    for (NSDictionary* entity in urls) {
        if (![entity isKindOfClass:[NSDictionary class]]) continue;
        NSString* expanded = NFBString(entity[@"expandedURL"]);
        if (expanded.length == 0) continue;

        // The t.co form first: once it is replaced, a display string that
        // happens to be a prefix of it can no longer match inside it.
        for (NSString* key in @[@"url", @"displayURL"]) {
            NSString* needle = NFBString(entity[key]);
            if (needle.length == 0 || [needle isEqualToString:expanded]) continue;
            [result replaceOccurrencesOfString:needle
                                    withString:expanded
                                       options:0
                                         range:NSMakeRange(0, result.length)];
        }
    }
    return [result copy];
}

NSString* const NFBProfileFieldName = @"name";
NSString* const NFBProfileFieldUsername = @"username";
NSString* const NFBProfileFieldBio = @"bio";
NSString* const NFBProfileFieldLocation = @"location";
NSString* const NFBProfileFieldWebsite = @"website";
NSString* const NFBProfileFieldProfileURL = @"profileURL";
NSString* const NFBProfileFieldUserID = @"userID";
NSString* const NFBProfileFieldJoined = @"joined";

NSString* NFBProfileCopyAllText(NSDictionary<NSString*, NSString*>* fields) {
    NSArray<NSArray<NSString*>*>* order = @[
        @[NFBProfileFieldName, @"Name"],
        @[NFBProfileFieldUsername, @"Username"],
        @[NFBProfileFieldBio, @"Bio"],
        @[NFBProfileFieldLocation, @"Location"],
        @[NFBProfileFieldWebsite, @"Website"],
        @[NFBProfileFieldProfileURL, @"Profile URL"],
        @[NFBProfileFieldUserID, @"User ID"],
        @[NFBProfileFieldJoined, @"Date joined"],
    ];

    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    NSCharacterSet* trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSArray<NSString*>* pair in order) {
        NSString* value = NFBString(fields[pair[0]]);
        if (value.length == 0 || NFBIsBlank(value)) continue;
        value = [value stringByTrimmingCharactersInSet:trim];

        if ([pair[0] isEqualToString:NFBProfileFieldUsername] && ![value hasPrefix:@"@"]) {
            value = [@"@" stringByAppendingString:value];
        }

        if ([pair[0] isEqualToString:NFBProfileFieldBio]) {
            [lines addObject:@"Bio:"];
            [lines addObject:value];
        } else {
            [lines addObject:[NSString stringWithFormat:@"%@: %@", pair[1], value]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Photo downloads

static NSSet<NSString*>* NFBPhotoExtensions(void) {
    static NSSet* extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    });
    return extensions;
}

NSString* NFBOriginalPhotoURLString(NSString* mediaURL) {
    if (mediaURL.length == 0) return nil;
    NSURLComponents* components = [NSURLComponents componentsWithString:mediaURL];
    if (!components.host.length || !components.path.length) return nil;
    components.scheme = @"https";

    NSString* format = nil;
    for (NSURLQueryItem* item in components.queryItems) {
        if ([item.name isEqualToString:@"format"] && item.value.length) format = item.value;
    }

    NSString* path = components.path;
    NSString* extension = path.pathExtension.lowercaseString;
    if ([NFBPhotoExtensions() containsObject:extension]) {
        if (!format) format = [extension isEqualToString:@"jpeg"] ? @"jpg" : extension;
        path = [path stringByDeletingPathExtension];
    }
    components.path = path;

    NSMutableArray<NSURLQueryItem*>* items = [NSMutableArray array];
    if (format) [items addObject:[NSURLQueryItem queryItemWithName:@"format" value:format]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"name" value:@"orig"]];
    components.queryItems = items;
    return components.URL.absoluteString;
}

NSString* NFBPhotoFileExtension(NSString* photoURL) {
    NSURLComponents* components = photoURL.length ? [NSURLComponents componentsWithString:photoURL] : nil;
    NSString* candidate = nil;
    for (NSURLQueryItem* item in components.queryItems) {
        if ([item.name isEqualToString:@"format"]) candidate = item.value.lowercaseString;
    }
    if (!candidate.length) candidate = components.path.pathExtension.lowercaseString;
    if ([candidate isEqualToString:@"jpeg"]) candidate = @"jpg";
    if ([candidate isEqualToString:@"png"] || [candidate isEqualToString:@"webp"]) return candidate;
    return @"jpg";
}

#pragma mark - Country filter

NSString* NFBCountryLookupKey(NSString* lowercaseName) {
    // NFKD, then drop the marks it split off: NSCharacterSet's nonBase set is
    // Unicode categories Mn, Mc and Me, the same set as JS's \p{M}.
    NSString* decomposed = [lowercaseName decomposedStringWithCompatibilityMapping];
    NSMutableString* key = [[[decomposed componentsSeparatedByCharactersInSet:NSCharacterSet.nonBaseCharacterSet]
        componentsJoinedByString:@""] mutableCopy];
    for (NSString* apostrophe in @[@"‘", @"’", @"ʼ"]) {
        [key replaceOccurrencesOfString:apostrophe
                             withString:@"'"
                                options:0
                                  range:NSMakeRange(0, key.length)];
    }
    return [key copy];
}

NSString* NFBCanonicalCountry(NSString* name, NSDictionary<NSString*, NSString*>* lookup) {
    if (![name isKindOfClass:[NSString class]]) return @"";
    NSString* trimmed =
        [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            .lowercaseString;
    if (trimmed.length == 0) return @"";

    NSArray* parts = [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* key = [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];

    NSString* canonical = lookup[NFBCountryLookupKey(key)];
    return canonical.length ? canonical : key;
}

BOOL NFBLocationIsBlocked(NSString* location, NSSet<NSString*>* blockedKeys,
                          NSDictionary<NSString*, NSArray<NSString*>*>* regionMembers,
                          NSDictionary<NSString*, NSString*>* lookup) {
    if (blockedKeys.count == 0) return NO;
    NSString* country = NFBCanonicalCountry(location, lookup);
    if (country.length == 0) return NO;
    if ([blockedKeys containsObject:country]) return YES;

    for (NSString* region in blockedKeys) {
        NSArray* members = regionMembers[region];
        if ([members isKindOfClass:[NSArray class]] && [members containsObject:country]) return YES;
    }
    return NO;
}

NSString* NFBExtractXPosedQueryID(NSString* javascriptSource) {
    if (javascriptSource.length == 0) return nil;
    NSRegularExpression* regex = [NSRegularExpression
        regularExpressionWithPattern:@"QUERY_ID\\s*:\\s*['\"]([A-Za-z0-9_-]{8,64})['\"]"
                             options:0
                               error:nil];
    NSTextCheckingResult* match =
        [regex firstMatchInString:javascriptSource options:0 range:NSMakeRange(0, javascriptSource.length)];
    if (!match) return nil;
    return [javascriptSource substringWithRange:[match rangeAtIndex:1]];
}

static NSString* NFBHeaderValue(NSDictionary* headers, NSString* name) {
    for (id key in headers) {
        if ([key isKindOfClass:[NSString class]] &&
            [(NSString*)key caseInsensitiveCompare:name] == NSOrderedSame) {
            return NFBString(headers[key]);
        }
    }
    return nil;
}

NSDate* NFBRateLimitResetDate(NSDictionary* headers, NSDate* now) {
    NSDate* latest = nil;

    NSString* reset = NFBHeaderValue(headers, @"x-rate-limit-reset");
    if (reset.length) {
        double seconds = reset.doubleValue;
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:seconds];
        if (seconds > 0 && [date compare:now] == NSOrderedDescending) latest = date;
    }

    NSString* retry = [NFBHeaderValue(headers, @"retry-after")
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (retry.length) {
        NSDate* date = nil;
        NSScanner* scanner = [NSScanner scannerWithString:retry];
        double seconds = 0;
        if ([scanner scanDouble:&seconds] && scanner.isAtEnd && seconds >= 0) {
            date = [now dateByAddingTimeInterval:seconds];
        } else {
            NSDateFormatter* http = [NSDateFormatter new];
            http.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            http.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
            http.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
            date = [http dateFromString:retry];
        }
        if (date && [date compare:now] == NSOrderedDescending &&
            (!latest || [date compare:latest] == NSOrderedDescending)) {
            latest = date;
        }
    }

    return latest ?: [now dateByAddingTimeInterval:60];
}

#pragma mark - GraphQL timeline rewriting

NSString* NFBGraphQLOperationName(NSURL* url) {
    NSArray<NSString*>* parts = url.path.pathComponents;
    NSUInteger index = [parts indexOfObject:@"graphql"];
    if (index == NSNotFound || parts.count == 0) return nil;
    NSString* last = parts.lastObject;
    return [last isEqualToString:@"graphql"] ? nil : last;
}

BOOL NFBIsHomeTimelineOperation(NSString* operationName) {
    return [operationName isEqualToString:@"HomeTimeline"] ||
           [operationName isEqualToString:@"HomeLatestTimeline"];
}

static NSString* NFBEntryID(NSDictionary* dict) {
    return NFBString(dict[@"entry_id"]) ?: NFBString(dict[@"entryId"]);
}

static BOOL NFBIsBottomCursorDictionary(NSDictionary* dict) {
    NSString* entryID = NFBEntryID(dict);
    if ([entryID hasPrefix:@"cursor-bottom"]) return YES;

    NSString* replaced = NFBString(dict[@"entry_id_to_replace"]) ?: NFBString(dict[@"entryIdToReplace"]);
    if ([replaced hasPrefix:@"cursor-bottom"]) return YES;

    // An entry whose content is a cursor of type Bottom, under either casing.
    if (entryID) {
        for (NSString* contentKey in @[@"content", @"item_content", @"itemContent"]) {
            NSDictionary* content = dict[contentKey];
            if (![content isKindOfClass:[NSDictionary class]]) continue;
            NSString* type = NFBString(content[@"cursor_type"]) ?: NFBString(content[@"cursorType"]);
            if ([type caseInsensitiveCompare:@"Bottom"] == NSOrderedSame) return YES;
        }
    }
    return NO;
}

static id NFBFilterTree(id node, BOOL (^drop)(NSDictionary*), NSUInteger* removed) {
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray* kept = [NSMutableArray arrayWithCapacity:[(NSArray*)node count]];
        for (id value in (NSArray*)node) {
            if ([value isKindOfClass:[NSDictionary class]] && drop(value)) {
                if (removed) (*removed)++;
                continue;
            }
            [kept addObject:NFBFilterTree(value, drop, removed)];
        }
        return kept;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary* copy = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary*)node count]];
        [(NSDictionary*)node enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL* stop) {
            copy[key] = NFBFilterTree(value, drop, removed);
        }];
        return copy;
    }
    return node;
}

id NFBRemoveBottomCursors(id json, NSUInteger* removed) {
    return NFBFilterTree(json, ^BOOL(NSDictionary* dict) {
        return NFBIsBottomCursorDictionary(dict);
    }, removed);
}

static void NFBCollectTopics(id node, BOOL underTopicKey, NSMutableArray* out, NSMutableSet* seen) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray*)node) NFBCollectTopics(value, underTopicKey, out, seen);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSDictionary* dict = node;

    if (underTopicKey) {
        NSString* name = NFBString(dict[@"name"]);
        NSString* topicID = nil;
        for (NSString* key in @[@"topic_id", @"topicId", @"rest_id", @"id_str", @"id"]) {
            topicID = NFBString(dict[key]);
            if (topicID.length) break;
        }
        if (name.length && topicID.length) {
            NSString* signature = [NSString stringWithFormat:@"%@\n%@", topicID, name.lowercaseString];
            if (![seen containsObject:signature]) {
                [seen addObject:signature];
                [out addObject:@{@"id": topicID, @"name": name}];
            }
        }
    }

    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL* stop) {
        BOOL topicKey = [key isKindOfClass:[NSString class]] &&
                        [(NSString*)key rangeOfString:@"topic" options:NSCaseInsensitiveSearch].location !=
                            NSNotFound;
        NFBCollectTopics(value, topicKey, out, seen);
    }];
}

NSArray<NSDictionary<NSString*, NSString*>*>* NFBTopicsInJSON(id node) {
    NSMutableArray* topics = [NSMutableArray array];
    NFBCollectTopics(node, NO, topics, [NSMutableSet set]);
    return [topics copy];
}

id NFBRemoveEntriesWithMutedTopics(id json, NSSet<NSString*>* mutedIDs, NSSet<NSString*>* mutedLowercaseNames,
                                   NSUInteger* removed) {
    if (mutedIDs.count == 0 && mutedLowercaseNames.count == 0) return json;
    return NFBFilterTree(json, ^BOOL(NSDictionary* dict) {
        if (!NFBEntryID(dict)) return NO;
        for (NSDictionary* topic in NFBTopicsInJSON(dict)) {
            if ([mutedIDs containsObject:topic[@"id"]]) return YES;
            if ([mutedLowercaseNames containsObject:[topic[@"name"] lowercaseString]]) return YES;
        }
        return NO;
    }, removed);
}

BOOL NFBIsTopicNegativeFeedbackOperation(NSString* operationName) {
    if ([operationName rangeOfString:@"Topic" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return NO;
    }
    for (NSString* verb in @[@"Snooze", @"NotInterested", @"StopRecommending", @"Mute", @"Dismiss", @"Hide"]) {
        if ([operationName rangeOfString:verb options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void NFBCollectTopicIDs(id node, NSMutableOrderedSet* out) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray*)node) NFBCollectTopicIDs(value, out);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    [(NSDictionary*)node enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL* stop) {
        BOOL idKey = [key isKindOfClass:[NSString class]] &&
                     ([@[@"topic_id", @"topicId", @"topic_ids", @"topicIds"] containsObject:key]);
        if (idKey) {
            NSArray* values = [value isKindOfClass:[NSArray class]] ? value : @[value];
            for (id candidate in values) {
                NSString* topicID = NFBString(candidate);
                if (topicID.length) [out addObject:topicID];
            }
        } else {
            NFBCollectTopicIDs(value, out);
        }
    }];
}

NSArray<NSString*>* NFBTopicIDsFromGraphQLRequest(NSURL* url, NSData* body) {
    NSMutableOrderedSet* ids = [NSMutableOrderedSet orderedSet];

    if (url) {
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* item in components.queryItems) {
            if (![item.name isEqualToString:@"variables"] || !item.value.length) continue;
            NSData* data = [item.value dataUsingEncoding:NSUTF8StringEncoding];
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NFBCollectTopicIDs(json, ids);
        }
    }

    if (body.length) {
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        NFBCollectTopicIDs(json, ids);
    }
    return ids.array;
}
