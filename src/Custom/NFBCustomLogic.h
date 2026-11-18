//
//  NFBCustomLogic.h
//  NeoFreeBird (custom tweaks)
//
//  Pure Foundation logic behind the custom tweaks: no UIKit, no Twitter
//  classes, no hooks. Everything here is deterministic so it can be compiled
//  and exercised by tests/CustomLogicTests.m on any Mac.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Copy All (profile details)

// Replaces t.co links and truncated display text ("bsky.app/profile/dril.b…")
// in `text` with each entity's expanded URL. `urls` holds dictionaries with
// optional "url", "displayURL" and "expandedURL" string values; entities
// without an expandedURL are left alone.
NSString* NFBExpandURLsInText(NSString* _Nullable text, NSArray<NSDictionary*>* _Nullable urls);

// Keys for NFBProfileCopyAllText.
extern NSString* const NFBProfileFieldName;
extern NSString* const NFBProfileFieldUsername;
extern NSString* const NFBProfileFieldBio;
extern NSString* const NFBProfileFieldLocation;
extern NSString* const NFBProfileFieldWebsite;
extern NSString* const NFBProfileFieldProfileURL;
extern NSString* const NFBProfileFieldUserID;
extern NSString* const NFBProfileFieldJoined;

// One block of text in a fixed order. Empty or whitespace-only fields are
// left out, the bio sits on its own lines after "Bio:", and the username is
// prefixed with "@" when it lacks one. Returns @"" when every field is empty.
NSString* NFBProfileCopyAllText(NSDictionary<NSString*, NSString*>* fields);

#pragma mark - Photo downloads

// Full-resolution URL for a pbs.twimg.com photo: "…/media/ID.jpg" and
// "…/media/ID?format=jpg&name=small" both become
// "https://pbs.twimg.com/media/ID?format=jpg&name=orig". Returns nil for nil,
// empty or unparseable input.
NSString* _Nullable NFBOriginalPhotoURLString(NSString* _Nullable mediaURL);

// File extension to save a photo URL under ("jpg", "png" or "webp"),
// defaulting to "jpg".
NSString* NFBPhotoFileExtension(NSString* _Nullable photoURL);

#pragma mark - Country filter (X-Posed parity)

// X-Posed's countryLookupKey(canonical lowercase text): NFKD, combining marks
// removed, typographic apostrophes folded to "'".
NSString* NFBCountryLookupKey(NSString* lowercaseName);

// X-Posed's canonicalCountry(): trims, lowercases and collapses whitespace,
// then resolves aliases through `lookup` (lookup key -> canonical name).
// Unknown names keep their lowercased spelling. nil/blank -> @"".
NSString* NFBCanonicalCountry(NSString* _Nullable name, NSDictionary<NSString*, NSString*>* lookup);

// X-Posed's matchingBlockedRegions() for whole-region selections: a location
// is blocked when its canonical name is selected directly (a country, or X's
// literal region label such as "europe") or belongs to a selected region.
// `regionMembers` maps region key -> canonical member country names.
BOOL NFBLocationIsBlocked(NSString* _Nullable location, NSSet<NSString*>* blockedKeys,
                          NSDictionary<NSString*, NSArray<NSString*>*>* regionMembers,
                          NSDictionary<NSString*, NSString*>* lookup);

// Pulls `QUERY_ID: '…'` (the AboutAccountQuery ID) out of X-Posed's
// extension/src/shared/constants.js. nil when absent or malformed.
NSString* _Nullable NFBExtractXPosedQueryID(NSString* _Nullable javascriptSource);

// When X's 429 cooldown ends: the later of x-rate-limit-reset (epoch
// seconds) and retry-after (seconds or HTTP date). Header names are matched
// case-insensitively. Falls back to now + 60 s when neither is usable.
NSDate* NFBRateLimitResetDate(NSDictionary* _Nullable headers, NSDate* now);

#pragma mark - GraphQL timeline rewriting

// Last path component of a GraphQL URL ("HomeLatestTimeline"), or nil.
NSString* _Nullable NFBGraphQLOperationName(NSURL* _Nullable url);

// The For You and Following feeds (HomeTimeline / HomeLatestTimeline).
BOOL NFBIsHomeTimelineOperation(NSString* _Nullable operationName);

// Removes bottom-cursor timeline entries (entry_id "cursor-bottom-…", or a
// cursor whose cursor_type is "Bottom") and TimelineReplaceEntry instructions
// that target one, so the app has nothing to page with. Top cursors survive,
// so pull-to-refresh keeps working. Returns a new tree; `removed` counts drops.
id NFBRemoveBottomCursors(id json, NSUInteger* _Nullable removed);

// Topics referenced anywhere inside `node`: every dictionary stored under a
// key containing "topic" that carries a name plus an id (topic_id, topicId,
// rest_id, id_str or id). Each result is @{@"id": …, @"name": …}; id may be
// @"" when only a name was found.
NSArray<NSDictionary<NSString*, NSString*>*>* NFBTopicsInJSON(id _Nullable node);

// Removes every timeline entry (a dictionary with entry_id/entryId) that
// references a muted topic, matched by id or by case-insensitive name.
id NFBRemoveEntriesWithMutedTopics(id json, NSSet<NSString*>* mutedIDs,
                                   NSSet<NSString*>* mutedLowercaseNames,
                                   NSUInteger* _Nullable removed);

// GraphQL operations that are X's own "less of this topic" actions: the name
// mentions Topic and one of Snooze, NotInterested, StopRecommending, Mute,
// Dismiss or Hide.
BOOL NFBIsTopicNegativeFeedbackOperation(NSString* _Nullable operationName);

// Topic IDs carried by a GraphQL request, from the "variables" query
// parameter (GET) or the JSON body (POST): values under topic_id, topicId,
// topic_ids or topicIds, at any depth.
NSArray<NSString*>* NFBTopicIDsFromGraphQLRequest(NSURL* _Nullable url, NSData* _Nullable body);

NS_ASSUME_NONNULL_END
