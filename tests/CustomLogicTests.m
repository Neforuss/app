// Tests for src/Custom/NFBCustomLogic.m. Plain Foundation, no XCTest, same
// shape as TerminologyTests.m. Run from the repository root:
//
//   clang -fobjc-arc -framework Foundation -Isrc src/Custom/NFBCustomLogic.m \
//       tests/CustomLogicTests.m -o /tmp/custom_logic_tests && /tmp/custom_logic_tests
//
// The country cases are not hand-written: tests/fixtures/xposed_vectors.json
// holds answers computed by X-Posed's own JavaScript (tools/xposed-sync), so
// these tests fail if the Objective-C port ever disagrees with X-Posed.

#import <Foundation/Foundation.h>
#import "Custom/NFBCustomLogic.h"

static NSUInteger failures = 0;
static NSUInteger checks = 0;

#define EXPECT(cond, fmt, ...)                                              \
    do {                                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            failures++;                                                     \
            NSLog(@"FAIL %s:%d " fmt, __FILE__, __LINE__, ##__VA_ARGS__);   \
        }                                                                   \
    } while (0)

static void ExpectString(NSString* actual, NSString* expected, NSString* label) {
    EXPECT([actual isEqualToString:expected] || (actual == nil && expected == nil),
           @"%@: got <%@>, expected <%@>", label, actual, expected);
}

static id LoadJSON(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        NSLog(@"FAIL missing fixture %@ (run from the repository root)", path);
        exit(1);
    }
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

#pragma mark - Copy All

static void TestURLExpansion(void) {
    NSArray* entities = @[
        @{@"url": @"https://t.co/abc", @"displayURL": @"patreon.com/dril", @"expandedURL": @"https://patreon.com/dril"},
        @{@"url": @"https://t.co/def", @"displayURL": @"bsky.app/profile/dril.b…",
          @"expandedURL": @"https://bsky.app/profile/dril.bsky.social"},
    ];
    ExpectString(NFBExpandURLsInText(@"welcome\nhttps://t.co/abc\nhttps://t.co/def", entities),
                 @"welcome\nhttps://patreon.com/dril\nhttps://bsky.app/profile/dril.bsky.social", @"t.co links");
    ExpectString(NFBExpandURLsInText(@"see bsky.app/profile/dril.b… now", entities),
                 @"see https://bsky.app/profile/dril.bsky.social now", @"truncated display text");
    ExpectString(NFBExpandURLsInText(@"no links", entities), @"no links", @"untouched");
    // Regression: display text is a substring of the expanded URL; already
    // expanded text must not become "https://https://…".
    ExpectString(NFBExpandURLsInText(@"https://patreon.com/dril and patreon.com/dril", entities),
                 @"https://patreon.com/dril and https://patreon.com/dril", @"already expanded text kept intact");
    ExpectString(NFBExpandURLsInText(nil, entities), @"", @"nil text");
    ExpectString(NFBExpandURLsInText(@"https://t.co/x", @[@{@"url": @"https://t.co/x"}]), @"https://t.co/x",
                 @"entity without expandedURL");
    ExpectString(NFBExpandURLsInText(@"https://t.co/x", nil), @"https://t.co/x", @"nil entities");
}

static void TestCopyAll(void) {
    NSDictionary* dril = @{
        NFBProfileFieldName: @"wint",
        NFBProfileFieldUsername: @"dril",
        NFBProfileFieldBio: @"welcome to my shit\nhttps://patreon.com/dril",
        NFBProfileFieldLocation: @"LA",
        NFBProfileFieldWebsite: @"https://linktr.ee/drilreal",
        NFBProfileFieldProfileURL: @"https://x.com/dril",
        NFBProfileFieldUserID: @"16298441",
        NFBProfileFieldJoined: @"September 15, 2008",
    };
    ExpectString(NFBProfileCopyAllText(dril),
                 @"Name: wint\nUsername: @dril\nBio:\nwelcome to my shit\nhttps://patreon.com/dril\nLocation: LA\n"
                 @"Website: https://linktr.ee/drilreal\nProfile URL: https://x.com/dril\nUser ID: 16298441\n"
                 @"Date joined: September 15, 2008",
                 @"full profile in the requested order");

    NSDictionary* sparse = @{NFBProfileFieldName: @"a", NFBProfileFieldUsername: @"@b", NFBProfileFieldBio: @"  \n ",
                             NFBProfileFieldLocation: @""};
    ExpectString(NFBProfileCopyAllText(sparse), @"Name: a\nUsername: @b", @"empty fields left out, @ not doubled");
    ExpectString(NFBProfileCopyAllText(@{}), @"", @"nothing to copy");
}

#pragma mark - Photos

static void TestPhotoURLs(void) {
    ExpectString(NFBOriginalPhotoURLString(@"https://pbs.twimg.com/media/GxYz123.jpg"),
                 @"https://pbs.twimg.com/media/GxYz123?format=jpg&name=orig", @"legacy extension form");
    ExpectString(NFBOriginalPhotoURLString(@"http://pbs.twimg.com/media/GxYz123.png"),
                 @"https://pbs.twimg.com/media/GxYz123?format=png&name=orig", @"http and png");
    ExpectString(NFBOriginalPhotoURLString(@"https://pbs.twimg.com/media/GxYz123?format=webp&name=small"),
                 @"https://pbs.twimg.com/media/GxYz123?format=webp&name=orig", @"query form keeps format");
    ExpectString(NFBOriginalPhotoURLString(@"https://pbs.twimg.com/media/GxYz123.jpeg"),
                 @"https://pbs.twimg.com/media/GxYz123?format=jpg&name=orig", @"jpeg normalised");
    ExpectString(NFBOriginalPhotoURLString(@"https://pbs.twimg.com/media/GxYz123"),
                 @"https://pbs.twimg.com/media/GxYz123?name=orig", @"no format known");
    ExpectString(NFBOriginalPhotoURLString(nil), nil, @"nil");
    ExpectString(NFBOriginalPhotoURLString(@"not a url"), nil, @"garbage");

    ExpectString(NFBPhotoFileExtension(@"https://pbs.twimg.com/media/A?format=png&name=orig"), @"png", @"ext png");
    ExpectString(NFBPhotoFileExtension(@"https://pbs.twimg.com/media/A?format=jpeg&name=orig"), @"jpg", @"ext jpeg");
    ExpectString(NFBPhotoFileExtension(@"https://pbs.twimg.com/media/A?name=orig"), @"jpg", @"ext default");
    ExpectString(NFBPhotoFileExtension(nil), @"jpg", @"ext nil");
}

#pragma mark - Country filter (parity with X-Posed)

static void TestCountryParity(void) {
    NSDictionary* data = LoadJSON(@"layout/Library/Application Support/BHT/BHTwitter.bundle/xposed_sync.json");
    NSDictionary* vectors = LoadJSON(@"tests/fixtures/xposed_vectors.json");
    NSDictionary* lookup = data[@"lookup"];
    NSMutableDictionary* members = [NSMutableDictionary dictionary];
    for (NSDictionary* region in data[@"regions"]) members[region[@"key"]] = region[@"members"];

    EXPECT([data[@"query_id"] length] > 0, @"bundled query ID present");
    EXPECT([data[@"countries"] count] > 200, @"country list looks complete (%lu)",
           (unsigned long)[data[@"countries"] count]);

    NSUInteger canonicalChecked = 0;
    for (NSDictionary* vector in vectors[@"canonical"]) {
        NSString* got = NFBCanonicalCountry(vector[@"input"], lookup);
        EXPECT([got isEqualToString:vector[@"expected"]], @"canonicalCountry(<%@>): got <%@>, X-Posed says <%@>",
               vector[@"input"], got, vector[@"expected"]);
        canonicalChecked++;
    }
    EXPECT(canonicalChecked > 100, @"canonical vectors loaded (%lu)", (unsigned long)canonicalChecked);

    NSUInteger blockingChecked = 0;
    for (NSDictionary* vector in vectors[@"blocking"]) {
        BOOL got = NFBLocationIsBlocked(vector[@"location"], [NSSet setWithArray:vector[@"blocked"]], members, lookup);
        EXPECT(got == [vector[@"expected"] boolValue], @"blocked(<%@>, %@): got %d, X-Posed says %@",
               vector[@"location"], vector[@"blocked"], got, vector[@"expected"]);
        blockingChecked++;
    }
    EXPECT(blockingChecked > 100, @"blocking vectors loaded (%lu)", (unsigned long)blockingChecked);

    EXPECT(!NFBLocationIsBlocked(@"Germany", [NSSet set], members, lookup), @"nothing selected blocks nothing");
}

static void TestQueryIDAndRateLimit(void) {
    ExpectString(NFBExtractXPosedQueryID(@"export const API_CONFIG = {\n    QUERY_ID: 'XRqGa7EeokUU5kppkh13EA', // x"),
                 @"XRqGa7EeokUU5kppkh13EA", @"query id");
    ExpectString(NFBExtractXPosedQueryID(@"QUERY_ID: \"abc-DEF_123456\""), @"abc-DEF_123456", @"double quotes");
    ExpectString(NFBExtractXPosedQueryID(@"QUERY_ID: 'x'"), nil, @"too short to be real");
    ExpectString(NFBExtractXPosedQueryID(nil), nil, @"nil source");

    NSDate* now = [NSDate dateWithTimeIntervalSince1970:1000000];
    NSDate* reset = NFBRateLimitResetDate(@{@"X-Rate-Limit-Reset": @"1000900"}, now);
    EXPECT(fabs(reset.timeIntervalSince1970 - 1000900) < 0.5, @"x-rate-limit-reset honoured");
    reset = NFBRateLimitResetDate(@{@"x-rate-limit-reset": @"1000900", @"Retry-After": @"1200"}, now);
    EXPECT(fabs(reset.timeIntervalSince1970 - 1001200) < 0.5, @"later deadline wins");
    reset = NFBRateLimitResetDate(@{@"retry-after": @"Mon, 12 Jan 1970 13:46:50 GMT"}, now);
    EXPECT(fabs(reset.timeIntervalSince1970 - 1000010) < 0.5, @"HTTP-date retry-after (%f)", reset.timeIntervalSince1970);
    reset = NFBRateLimitResetDate(@{@"x-rate-limit-reset": @"5"}, now);
    EXPECT(fabs(reset.timeIntervalSince1970 - 1000060) < 0.5, @"past deadline falls back to 60 s");
    reset = NFBRateLimitResetDate(nil, now);
    EXPECT(fabs(reset.timeIntervalSince1970 - 1000060) < 0.5, @"no headers falls back to 60 s");
}

#pragma mark - GraphQL rewriting

static NSDictionary* Entry(NSString* entryID, NSDictionary* content) {
    return @{@"entry_id": entryID, @"content": content ?: @{}};
}

static void TestCursorStripping(void) {
    ExpectString(NFBGraphQLOperationName([NSURL URLWithString:@"https://api.x.com/graphql/abc123/HomeLatestTimeline?x=1"]),
                 @"HomeLatestTimeline", @"op name");
    ExpectString(NFBGraphQLOperationName([NSURL URLWithString:@"https://api.x.com/1.1/statuses.json"]), nil,
                 @"not graphql");
    EXPECT(NFBIsHomeTimelineOperation(@"HomeTimeline") && NFBIsHomeTimelineOperation(@"HomeLatestTimeline"),
           @"home ops");
    EXPECT(!NFBIsHomeTimelineOperation(@"UserTweets") && !NFBIsHomeTimelineOperation(nil), @"non-home ops");

    NSDictionary* response = @{@"data": @{@"timeline": @{@"instructions": @[
        @{@"type": @"TimelineAddEntries", @"entries": @[
            Entry(@"tweet-1", nil),
            Entry(@"cursor-top-99", @{@"cursor_type": @"Top"}),
            Entry(@"cursor-bottom-98", @{@"cursor_type": @"Bottom"}),
            Entry(@"some-other-id", @{@"cursor_type": @"Bottom"}),
        ]},
        @{@"type": @"TimelineReplaceEntry", @"entry_id_to_replace": @"cursor-bottom-97", @"entry": @{}},
        @{@"type": @"TimelineReplaceEntry", @"entry_id_to_replace": @"cursor-top-96", @"entry": @{}},
    ]}}};
    NSUInteger removed = 0;
    NSDictionary* stripped = NFBRemoveBottomCursors(response, &removed);
    NSArray* instructions = stripped[@"data"][@"timeline"][@"instructions"];
    NSArray* entries = instructions[0][@"entries"];
    EXPECT(removed == 3, @"three bottom cursors removed (got %lu)", (unsigned long)removed);
    EXPECT(entries.count == 2 && [entries[0][@"entry_id"] isEqualToString:@"tweet-1"] &&
               [entries[1][@"entry_id"] isEqualToString:@"cursor-top-99"],
           @"tweets and top cursor kept: %@", entries);
    EXPECT(instructions.count == 2, @"replace of top cursor kept, of bottom cursor dropped");

    removed = 0;
    NFBRemoveBottomCursors(@{@"a": @[@1, @"x", @{@"b": @2}]}, &removed);
    EXPECT(removed == 0, @"nothing to strip");
    NFBRemoveBottomCursors(@[], NULL);  // NULL counter must be accepted
}

static void TestTopics(void) {
    NSDictionary* topicEntry = Entry(@"tweet-7", @{@"item_content": @{
        @"social_context": @{@"type": @"TopicContext", @"topic": @{@"topic_id": @"111", @"name": @"Formula 1"}}}});
    NSDictionary* otherTopic = Entry(@"tweet-8", @{@"socialContext": @{@"topic": @{@"rest_id": @"222", @"name": @"Cats"}}});
    NSDictionary* plain = Entry(@"tweet-9", @{@"text": @"no topic, but a name field", @"name": @"x"});
    NSDictionary* response = @{@"entries": @[topicEntry, otherTopic, plain]};

    NSArray* found = NFBTopicsInJSON(response);
    EXPECT(found.count == 2, @"two topics found: %@", found);
    // Conditions holding multi-element literals are parenthesised: the
    // preprocessor would otherwise split the macro arguments at their commas.
    EXPECT(([found containsObject:@{@"id": @"111", @"name": @"Formula 1"}]), @"snake_case topic");
    EXPECT(([found containsObject:@{@"id": @"222", @"name": @"Cats"}]), @"camelCase / rest_id topic");

    NSUInteger removed = 0;
    NSDictionary* byID = NFBRemoveEntriesWithMutedTopics(response, [NSSet setWithObject:@"111"], [NSSet set], &removed);
    EXPECT(removed == 1 && [byID[@"entries"] count] == 2, @"muted by id");

    removed = 0;
    NSDictionary* byName =
        NFBRemoveEntriesWithMutedTopics(response, [NSSet set], [NSSet setWithObject:@"cats"], &removed);
    EXPECT(removed == 1 && [byName[@"entries"] count] == 2, @"muted by case-insensitive name");

    removed = 0;
    id same = NFBRemoveEntriesWithMutedTopics(response, [NSSet set], [NSSet set], &removed);
    EXPECT(same == response && removed == 0, @"nothing muted returns the input untouched");

    EXPECT(NFBIsTopicNegativeFeedbackOperation(@"SnoozeTopic"), @"snooze");
    EXPECT(NFBIsTopicNegativeFeedbackOperation(@"TopicNotInterested"), @"not interested");
    EXPECT(NFBIsTopicNegativeFeedbackOperation(@"TopicStopRecommending"), @"stop recommending");
    EXPECT(!NFBIsTopicNegativeFeedbackOperation(@"TopicFollow"), @"follow is not negative");
    EXPECT(!NFBIsTopicNegativeFeedbackOperation(@"MuteUser"), @"muting a user is not a topic action");
    EXPECT(!NFBIsTopicNegativeFeedbackOperation(nil), @"nil op");
    EXPECT(!NFBIsTopicNegativeFeedbackOperation(@""), @"empty op");

    NSURL* getURL = [NSURL URLWithString:@"https://api.x.com/graphql/q/SnoozeTopic?variables=%7B%22topicId%22%3A%22555%22%7D"];
    EXPECT([NFBTopicIDsFromGraphQLRequest(getURL, nil) isEqualToArray:@[@"555"]], @"GET variables");
    NSData* body = [@"{\"variables\":{\"topic_ids\":[\"1\",2],\"other\":{\"topic_id\":\"3\"}}}"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSArray* ids = NFBTopicIDsFromGraphQLRequest(nil, body);
    EXPECT(([[NSSet setWithArray:ids] isEqualToSet:[NSSet setWithArray:@[@"1", @"2", @"3"]]] && ids.count == 3),
           @"POST body ids, nested and numeric: %@", ids);
    EXPECT(NFBTopicIDsFromGraphQLRequest(nil, [@"not json" dataUsingEncoding:NSUTF8StringEncoding]).count == 0,
           @"garbage body");
}

int main(void) {
    @autoreleasepool {
        TestURLExpansion();
        TestCopyAll();
        TestPhotoURLs();
        TestCountryParity();
        TestQueryIDAndRateLimit();
        TestCursorStripping();
        TestTopics();
        if (failures) {
            NSLog(@"%lu of %lu checks FAILED", (unsigned long)failures, (unsigned long)checks);
            return 1;
        }
        NSLog(@"all %lu checks passed", (unsigned long)checks);
    }
    return 0;
}
