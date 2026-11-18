//
//  NFBMutedTopics.h
//  NeoFreeBird (custom tweaks)
//
//  Permanent topic mutes. X's Snooze lasts 24 hours; a topic muted here stays
//  muted until it is removed from the list in settings.
//
//  A topic gets on the list three ways:
//   1. X's own "less of this topic" actions (Snooze / Not interested / Stop
//      recommending), captured from the GraphQL request that carries the
//      topic ID, and from the status-view event handlers that carry the topic;
//   2. typed in by name on the Muted Topics screen;
//  and is enforced by removing timeline entries that reference a muted topic
//  (by ID or name) from GraphQL responses and from timeline sections.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const NFBMutedTopicsDidChangeNotification;

@interface NFBMutedTopics : NSObject

+ (instancetype)shared;

// Each entry: @{@"id": NSString (may be @""), @"name": NSString (may be @""),
// @"added": NSDate}. Newest first.
// Atomic: the GraphQL response hook reads these off the main thread while
// the settings screen writes them on it. Mutations happen on the main thread.
@property (atomic, copy, readonly) NSArray<NSDictionary*>* topics;
@property (atomic, copy, readonly) NSSet<NSString*>* mutedIDs;
@property (atomic, copy, readonly) NSSet<NSString*>* mutedLowercaseNames;

// YES when the setting is on and the list is non-empty.
@property (nonatomic, readonly) BOOL isActive;

// Adds a topic (no-op when already muted by that ID or name).
- (void)muteTopicID:(nullable NSString*)topicID name:(nullable NSString*)name;
- (void)removeTopicAtIndex:(NSUInteger)index;

// Records id -> name pairs seen in timeline responses, so a topic muted by
// ID alone (from a snooze request) gets a readable name in settings.
- (void)learnTopics:(NSArray<NSDictionary<NSString*, NSString*>*>*)topics;
- (nullable NSString*)knownNameForTopicID:(NSString*)topicID;

@end

NS_ASSUME_NONNULL_END
