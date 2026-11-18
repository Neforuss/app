//
//  Avatars.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// Avatar style 2 is the circular default; style 3 is the rounded-square style
// the app itself uses for organization accounts (corner radius = width / 8).
// Coercing the style makes the views handle masking, corner radius, shadow
// layers and the image pipeline natively.

@interface TFNAvatarImageView : UIView
@property (nonatomic) NSInteger style;
@end

@interface TUIAvatarImageView : TFNAvatarImageView
@end

// Coerced views are marked so disabling the setting can restore just those,
// leaving avatars that are natively rounded squares alone.
static char kCoercedAvatarStyle;
static char kAvatarBarOriginalBackground;
static char kDashAvatarOriginalBorderWidth;
static char kSharpAvatarOriginalRadius;

// "Sharp corners" (custom) goes one step past square: style 3 is still a
// rounded square (radius = width / 8), so sharp also zeroes the radius.
static BOOL SharpAvatarsEnabled(void) {
    return [BHTSettings boolForKey:@"sharp_avatars"];
}

static BOOL SquareAvatarsEnabled(void) {
    return [BHTSettings boolForKey:@"square_avatars"] || SharpAvatarsEnabled();
}

// Zeroes the corner radius on the avatar and the layers it draws into, and
// puts back the original radius once the setting is off again.
static void UpdateSharpAvatarCorners(UIView* avatar) {
    NSMutableArray<UIView*>* views = [NSMutableArray arrayWithObject:avatar];
    CGSize size = avatar.bounds.size;
    for (UIView* child in avatar.subviews) {
        // Only the picture itself; small overlays (verified / affiliate
        // badges, live rings drawn as subviews) keep their own shape.
        if (child.bounds.size.width >= size.width * 0.8 && child.bounds.size.height >= size.height * 0.8) {
            [views addObject:child];
        }
    }
    for (UIView* view in views) {
        NSNumber* original = objc_getAssociatedObject(view, &kSharpAvatarOriginalRadius);
        if (SharpAvatarsEnabled()) {
            if (view.layer.cornerRadius > 0) {
                if (!original) {
                    objc_setAssociatedObject(view, &kSharpAvatarOriginalRadius,
                                             @(view.layer.cornerRadius),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                view.layer.cornerRadius = 0;
            }
        } else if (original) {
            view.layer.cornerRadius = original.doubleValue;
            objc_setAssociatedObject(view, &kSharpAvatarOriginalRadius, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void UpdateDashAvatarDecorations(UIView* avatar) {
    Class dashAvatarClass = objc_getClass("_TtC11TwitterDash19DashAvatarImageView");
    if (!dashAvatarClass || ![avatar isKindOfClass:dashAvatarClass]) return;

    BOOL square = SquareAvatarsEnabled();
    UpdateSharpAvatarCorners(avatar);
    NSNumber* borderWidth = objc_getAssociatedObject(avatar,
                                                      &kDashAvatarOriginalBorderWidth);
    if (square) {
        if (!borderWidth) {
            objc_setAssociatedObject(avatar, &kDashAvatarOriginalBorderWidth,
                                     @(avatar.layer.borderWidth),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (avatar.layer.borderWidth != 0) avatar.layer.borderWidth = 0;
        Class avatarClass = objc_getClass("TFNAvatarImageView");
        Ivar shadowIvar = avatarClass ? class_getInstanceVariable(
            avatarClass, "_circularShadowLayer") : NULL;
        CALayer* shadow = shadowIvar ? object_getIvar(avatar, shadowIvar) : nil;
        if (shadow && !shadow.hidden) shadow.hidden = YES;
    } else if (borderWidth) {
        avatar.layer.borderWidth = borderWidth.doubleValue;
        objc_setAssociatedObject(avatar, &kDashAvatarOriginalBorderWidth, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSHashTable* AvatarBarItems(void) {
    static NSHashTable* items;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = [NSHashTable weakObjectsHashTable];
    });
    return items;
}

static void RefreshAvatarBarBackgrounds(void) {
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    for (UIBarButtonItem* item in AvatarBarItems().allObjects) {
        NSNumber* original = objc_getAssociatedObject(item,
                                                       &kAvatarBarOriginalBackground);
        if (original && [item respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter,
                                                    original.boolValue);
        }
    }
}

static NSInteger CoercedStyle(UIView* view, NSInteger style) {
    if (style == 2) {
        if (SquareAvatarsEnabled()) {
            objc_setAssociatedObject(view, &kCoercedAvatarStyle, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return 3;
        }
        objc_setAssociatedObject(view, &kCoercedAvatarStyle, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return style;
}

void applySquareAvatarsSetting(void) {
    BOOL enabled = SquareAvatarsEnabled();
    Class avatarClass = objc_getClass("TFNAvatarImageView");

    RefreshAvatarBarBackgrounds();

    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        EnumerateSubviewsRecursively(window, ^(UIView* view) {
            if (![view isKindOfClass:avatarClass]) {
                return;
            }

            TFNAvatarImageView* avatar = (TFNAvatarImageView*)view;
            if (enabled
                    ? avatar.style == 2
                    : objc_getAssociatedObject(avatar, &kCoercedAvatarStyle) != nil) {
                // Re-sent as circular; the hook coerces it when the setting is on.
                [avatar setStyle:2];
            }
            UpdateDashAvatarDecorations(avatar);
            UpdateSharpAvatarCorners(avatar);
        });
    }
}

%hook TFNAvatarImageView

- (void)setStyle:(NSInteger)style {
    %orig(CoercedStyle(self, style));
}

// The style setter re-applies its corner radius during layout, so the sharp
// override has to run after every layout pass, not once.
- (void)layoutSubviews {
    %orig;
    UpdateSharpAvatarCorners((UIView*)self);
}

%end

%hook _TtC11TwitterDash19DashAvatarImageView

- (void)layoutSubviews {
    %orig;
    UpdateDashAvatarDecorations((UIView*)self);
}

%end

// Force disable the Liquid Glass border
%group AvatarBarGlass
%hook _TtC11TwitterDash26TabRootAvatarBarButtonItem

- (void)setHidesSharedBackground:(BOOL)hidden {
    objc_setAssociatedObject(self, &kAvatarBarOriginalBackground, @(hidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [AvatarBarItems() addObject:self];
    %orig(SquareAvatarsEnabled() ? YES : hidden);
}

%end
%end

%ctor {
    %init(_ungrouped);
    if (class_getInstanceMethod([UIBarButtonItem class],
                                NSSelectorFromString(@"setHidesSharedBackground:"))) {
        %init(AvatarBarGlass);
    }
}

// TUIAvatarImageView picks its circular pre-clip image transformer from the
// incoming style, so coerce before its own logic runs. Its style mapping class
// method also feeds the Swift avatar views, whose setter is unreachable from
// ObjC.
%hook TUIAvatarImageView

- (void)setStyle:(NSInteger)style {
    %orig(CoercedStyle(self, style));
}

+ (NSInteger)avatarImageViewStyleWithProfileImageShape:(NSInteger)shape
                                          identityType:(NSInteger)identityType {
    return SquareAvatarsEnabled() ? 3 : %orig;
}

%end

// Some fetch helpers install the circular transformer unconditionally, so
// images that get pre-clipped are rounded as squares instead of circles.
%hook UIImage

- (UIImage*)tfn_roundImageWithTargetDimensions:(CGSize)targetDimensions
                             targetContentMode:
                                 (UIViewContentMode)targetContentMode {
    if (!SquareAvatarsEnabled()) {
        return %orig;
    }

    if (targetDimensions.width <= 0 || targetDimensions.height <= 0) {
        return self;
    }

    CGRect imageRect =
        CGRectMake(0, 0, targetDimensions.width, targetDimensions.height);
    CGFloat cornerRadius = SharpAvatarsEnabled()
                               ? 0
                               : MIN(targetDimensions.width, targetDimensions.height) / 8.0;

    UIGraphicsBeginImageContextWithOptions(targetDimensions, NO, self.scale);
    if (!UIGraphicsGetCurrentContext()) {
        UIGraphicsEndImageContext();
        return self;
    }

    [[UIBezierPath bezierPathWithRoundedRect:imageRect
                                cornerRadius:cornerRadius] addClip];
    [self drawInRect:imageRect];

    UIImage* roundedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return roundedImage ?: self;
}

%end

%hook TFNCircularAvatarShadowLayer

- (void)setHidden:(BOOL)hidden {
    %orig(SquareAvatarsEnabled() ? YES : hidden);
}

%end
