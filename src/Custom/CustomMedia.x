//
//  CustomMedia.x
//  NeoFreeBird (custom tweaks)
//
//  - Never autoplay GIFs, independent of the video autoplay setting.
//  - Sharp (square) corners on photo / video / GIF previews in posts.
//  - Open the home feed on Following instead of For You.
//
//  Hook points come from NeoFreeBird/classdump (T1Twitter, Sept 2025). Every
//  hook is installed only when its class and selector exist at runtime, so a
//  rename in a future X build switches the feature off instead of crashing.
//

#import "Hooks/HookHelpers.h"
#import "Custom/NFBRuntime.h"

#pragma mark - GIF autoplay

// Whether an autoplay candidate is a GIF. The autoplayable is usually a player
// view or controller; the GIF flag lives on its player session source
// (TVPPlayerSessionSource.isGIF) or on the media entity (mediaType 2 /
// isAnimatedGif). Probe a small, type-checked neighbourhood of objects.
static BOOL NFBObjectDescribesGIF(id object) {
    if (!object) return NO;
    BOOL found = NO;
    for (NSString* name in @[@"isGIF", @"isAnimatedGif", @"isAnimatedGIF", @"animatedGIF"]) {
        BOOL value = NFBGetBool(object, name, &found);
        if (found) return value;
    }
    long long mediaType = NFBGetInteger(object, @"mediaType", -1);
    return mediaType == 2;
}

static BOOL NFBAutoplayableIsGIF(id autoplayable) {
    if (NFBObjectDescribesGIF(autoplayable)) return YES;

    NSArray<NSString*>* hops = @[
        @"playerSessionSource", @"sessionSource", @"playerSource", @"source", @"mediaInfo",
        @"primaryMediaInfo", @"mediaEntity", @"viewModel", @"attachment", @"media",
        @"autoplayableView", @"inlineMediaInfo", @"playable"
    ];
    for (NSString* hop in hops) {
        id first = NFBGetObject(autoplayable, hop);
        if (!first || first == autoplayable) continue;
        if (NFBObjectDescribesGIF(first)) return YES;
        for (NSString* inner in @[@"mediaEntity", @"primaryMediaInfo", @"playerSessionSource", @"sessionSource"]) {
            if (NFBObjectDescribesGIF(NFBGetObject(first, inner))) return YES;
        }
    }

    // Last resort: the view itself. GIF players are named as such in X's
    // Swift modules (for example "...AnimatedGif..."), video players are not.
    id view = NFBGetObject(autoplayable, @"autoplayableView");
    id subject = view ?: autoplayable;
    if (!subject) return NO;  // nil would answer rangeOfString with location 0, i.e. "found"
    NSString* className = NSStringFromClass([subject class]);
    return className.length &&
           [className rangeOfString:@"gif" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

%group NFBGIFAutoplay
%hook T1AccountAutoplayPolicy

- (_Bool)autoplayableIsEligibleForAutoplayWithAutoplayable:(id)autoplayable environment:(id)environment {
    if ([BHTSettings boolForKey:@"disable_gif_autoplay"] && NFBAutoplayableIsGIF(autoplayable)) {
        return NO;
    }
    return %orig;
}

%end
%end

#pragma mark - Sharp media corners

static BOOL NFBSharpMedia(void) {
    return [BHTSettings boolForKey:@"sharp_media_corners"];
}

static char kNFBOriginalMediaRadius;

// Whether `view` is media filling (most of) `container`, as opposed to an
// overlay drawn on top of it: GIF / ALT / duration pills, the play button,
// badges. Only fill views get square corners; overlays keep theirs.
// `minFraction` is the share of the container a view must cover on both
// axes: 0.6 for single media, 0.25 for the multi-photo grid, whose tiles are
// about half the container each while its pills stay far smaller.
static BOOL NFBIsFillView(UIView* view, UIView* container, CGFloat minFraction) {
    if (view == container) return YES;
    CGSize outer = container.bounds.size;
    CGSize inner = view.bounds.size;
    return outer.width > 0 && outer.height > 0 && inner.width >= outer.width * minFraction &&
           inner.height >= outer.height * minFraction;
}

// Zeroes the corner radius on a media container and the image/video layers
// it clips (two levels down is where X nests them), remembering the original
// so turning the setting off restores it without a relaunch.
static void NFBApplySharpMediaCorners(UIView* container, CGFloat minFraction) {
    BOOL sharp = NFBSharpMedia();
    NSMutableArray<UIView*>* views = [NSMutableArray arrayWithObject:container];
    for (UIView* child in container.subviews) {
        [views addObject:child];
        [views addObjectsFromArray:child.subviews];
    }
    for (UIView* view in views) {
        NSNumber* original = objc_getAssociatedObject(view, &kNFBOriginalMediaRadius);
        if (sharp && !NFBIsFillView(view, container, minFraction)) continue;
        if (sharp) {
            if (view.layer.cornerRadius > 0) {
                if (!original) {
                    objc_setAssociatedObject(view, &kNFBOriginalMediaRadius, @(view.layer.cornerRadius),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                view.layer.cornerRadius = 0;
            }
        } else if (original) {
            view.layer.cornerRadius = original.doubleValue;
            objc_setAssociatedObject(view, &kNFBOriginalMediaRadius, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// The radius the timeline layout asks for, used by the classic status cell.
%group NFBSharpMediaLayoutSpec
%hook T1StatusViewAttachmentLayoutSpec
+ (double)photoVideoCornerRadiusForOptions:(unsigned long long)options {
    return NFBSharpMedia() ? 0 : %orig;
}
%end
%end

// The Swift multi-photo grid. Its borderCornerRadius property is left alone
// (overwriting it would lose the value needed to restore it live); the
// layers it produces are squared after each layout pass instead.
%group NFBSharpMultiMediaLayout
%hook _TtC21TweetMediaAttachments14MultiMediaView
- (void)layoutSubviews {
    %orig;
    NFBApplySharpMediaCorners((UIView*)self, 0.25);
}
%end
%end

%group NFBSharpInlineMediaLayout
%hook T1InlineMediaContainerView
- (void)layoutSubviews {
    %orig;
    NFBApplySharpMediaCorners((UIView*)self, 0.6);
}
%end
%end

#pragma mark - Open on Following

// Once per launch, the first time the home container appears, select the
// Following tab. Later tab changes are the user's and are left alone.
static BOOL nfbDidApplyDefaultTab = NO;

static UIViewController* NFBFindSegmentedController(UIViewController* root, NSUInteger depth) {
    Class segmentedClass = NSClassFromString(@"TFNScrollingSegmentedViewController");
    if (!root || !segmentedClass || depth > 4) return nil;
    if ([root isKindOfClass:segmentedClass]) return root;
    for (UIViewController* child in root.childViewControllers) {
        UIViewController* found = NFBFindSegmentedController(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NSString* NFBSegmentTitle(UIViewController* segmented, long long index) {
    SEL selector = NSSelectorFromString(@"_tfn_textForHorizontalBarViewItemAtIndex:");
    if (![segmented respondsToSelector:selector]) return nil;
    NSMethodSignature* signature = [segmented methodSignatureForSelector:selector];
    if (signature.methodReturnType[0] != '@') return nil;
    @try {
        id title = ((id (*)(id, SEL, long long))objc_msgSend)(segmented, selector, index);
        if ([title isKindOfClass:[NSAttributedString class]]) title = [(NSAttributedString*)title string];
        return [title isKindOfClass:[NSString class]] ? title : nil;
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

// Index of the Following tab: matched by title when X's own "Following"
// string can be read, otherwise the second built-in tab (X's layout since
// 2023 is For you | Following | pinned lists).
static long long NFBFollowingTabIndex(UIViewController* segmented) {
    NSString* forYou = [[BHTBundle sharedBundle] localizedTwitterStringForKey:@"HOME_TIMELINE_FOR_YOU_TAB_TITLE"];
    NSMutableSet<NSString*>* followingTitles = [NSMutableSet setWithArray:@[@"following"]];
    for (NSString* key in @[@"HOME_TIMELINE_FOLLOWING_TAB_TITLE", @"FOLLOWING_TAB_TITLE", @"FOLLOWING"]) {
        NSString* localized = [[BHTBundle sharedBundle] localizedTwitterStringForKey:key];
        if (localized.length && ![localized isEqualToString:key]) [followingTitles addObject:localized.lowercaseString];
    }
    for (long long index = 0; index < 6; index++) {
        NSString* title = NFBSegmentTitle(segmented, index);
        if (!title) break;
        if ([followingTitles containsObject:title.lowercaseString]) return index;
    }
    NSString* first = NFBSegmentTitle(segmented, 0);
    BOOL firstIsForYou = !first || [first caseInsensitiveCompare:@"For you"] == NSOrderedSame ||
                         (forYou.length && [first caseInsensitiveCompare:forYou] == NSOrderedSame);
    return firstIsForYou ? 1 : -1;
}

static void NFBSelectFollowingTab(UIViewController* container) {
    if (nfbDidApplyDefaultTab || ![BHTSettings boolForKey:@"default_to_following"]) return;

    UIViewController* segmented = NFBFindSegmentedController(container, 0);
    if (!segmented) {
        NFBCustomLog(@"default tab: no TFNScrollingSegmentedViewController under %@", container.class);
        return;
    }
    nfbDidApplyDefaultTab = YES;

    long long target = NFBFollowingTabIndex(segmented);
    long long current = NFBGetInteger(segmented, @"selectedIndex", -1);
    if (target < 0 || target == current) return;

    // Prefer the tap path (the segmented controller's own label-view delegate
    // method) so the container loads and scribes the tab as if the user chose
    // it; fall back to the plain selectedIndex setter.
    SEL tapSelector = NSSelectorFromString(@"horizontalLabelView:didSelectItemAtIndex:");
    UIView* labelView = nil;
    if ([segmented respondsToSelector:tapSelector]) {
        for (UIView* candidate in segmented.view.subviews) {
            if ([NSStringFromClass(candidate.class) rangeOfString:@"HorizontalLabel"].location != NSNotFound) {
                labelView = candidate;
                break;
            }
        }
    }
    @try {
        if (labelView) {
            ((void (*)(id, SEL, id, long long))objc_msgSend)(segmented, tapSelector, labelView, target);
        } else if ([segmented respondsToSelector:@selector(setSelectedIndex:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(segmented, @selector(setSelectedIndex:), target);
        }
        NFBCustomLog(@"default tab: selected index %lld (was %lld)", target, current);
    } @catch (NSException* exception) {
        NFBCustomLog(@"default tab: selection failed: %@", exception);
    }
}

%group NFBDefaultTabSwift
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NFBSelectFollowingTab((UIViewController*)self);
}
%end
%end

// The older Objective-C container restores the last tab through this getter;
// answering with the Following (latest) timeline on the first call per launch
// is the cleanest switch where it exists.
%group NFBDefaultTabObjC
%hook THFHomeTimelineContainerViewController
- (id)_t1_lastSelectedTimelineViewController {
    if (!nfbDidApplyDefaultTab && [BHTSettings boolForKey:@"default_to_following"]) {
        id latest = NFBGetObject(self, @"latestTimelineViewController");
        if (latest) {
            nfbDidApplyDefaultTab = YES;
            return latest;
        }
    }
    return %orig;
}
%end
%end

%ctor {
    if (NFBInstancesRespond(@"T1AccountAutoplayPolicy",
                            @selector(autoplayableIsEligibleForAutoplayWithAutoplayable:environment:))) {
        %init(NFBGIFAutoplay);
    } else {
        NFBCustomLog(@"GIF autoplay hook unavailable in this X build");
    }

    if (NFBClassResponds(@"T1StatusViewAttachmentLayoutSpec", @selector(photoVideoCornerRadiusForOptions:))) {
        %init(NFBSharpMediaLayoutSpec);
    }
    if (NSClassFromString(@"_TtC21TweetMediaAttachments14MultiMediaView")) {
        %init(NFBSharpMultiMediaLayout);
    }
    if (NSClassFromString(@"T1InlineMediaContainerView")) {
        %init(NFBSharpInlineMediaLayout);
    }

    if (NSClassFromString(@"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController")) {
        %init(NFBDefaultTabSwift);
    }
    if (NFBInstancesRespond(@"THFHomeTimelineContainerViewController",
                            NSSelectorFromString(@"_t1_lastSelectedTimelineViewController"))) {
        %init(NFBDefaultTabObjC);
    }
}
