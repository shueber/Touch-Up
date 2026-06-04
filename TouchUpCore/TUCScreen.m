//
//  TUCScreen.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import "TUCScreen.h"
#import <dlfcn.h>

@interface TUCScreen ()
+ (nullable NSScreen *)systemScreenForDisplayID:(CGDirectDisplayID)displayID;
- (nullable NSString *)edidNameForDisplayID:(CGDirectDisplayID)displayID;
@end

@implementation TUCScreen

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
               frameOfFirstScreen:(CGRect)firstFrame {
    if (self = [super init]) {
        self.id = displayID;

        CFUUIDRef cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID);
        if (cfUUID) {
            self.uuid = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, cfUUID);
            CFRelease(cfUUID);
        }

        self.rotation = CGDisplayRotation(displayID);

        // Native physical size (mm) of this exact panel — mirror-independent (it is the
        // panel's own EDID, not the shared mirror content). Note: `CGDisplayScreenSize`
        // swaps width/height with the panel's rotation, so this is in the same on-screen
        // orientation as `rotation`/`frame`, not the built-in orientation.
        self.nativePhysicalSize = CGDisplayScreenSize(displayID);

        // Native pixel resolution: the *largest* mode the panel advertises, not the
        // current one. While mirroring, the current mode is forced to the shared mirror
        // resolution, which is not this panel's own grid; the max mode is the panel's own.
        // Like the physical size, mode dimensions swap with rotation.
        self.nativeResolution = [self largestModePixelSizeForDisplayID:displayID];

        // The name belongs to this exact panel. Prefer its own NSScreen's localized name,
        // but a hardware-mirrored secondary has no NSScreen — fall back to its EDID product
        // name (read by display ID, independent of mirroring), then to a generic label.
        NSScreen *ownScreen = [TUCScreen systemScreenForDisplayID:displayID];
        if (@available(macOS 10.15, *)) {
            self.name = ownScreen.localizedName;
        }
        if (self.name == nil) {
            self.name = [self edidNameForDisplayID:displayID];
        }
        if (self.name == nil) {
            self.name = [NSString stringWithFormat:@"Display %u", displayID];
        }

        // Logical layout comes from the backing NSScreen. A hardware-mirrored secondary
        // panel has no NSScreen of its own — it shows the master's content — so fall back
        // to the master's NSScreen.
        NSScreen *backing = [self systemScreen];
        if (backing) {
            CGRect thisFrame = backing.frame;
            // Flip from AppKit's bottom-left origin to a top-left-origin space.
            self.frame = CGRectMake(thisFrame.origin.x,
                                    thisFrame.origin.y + thisFrame.size.height - firstFrame.size.height,
                                    thisFrame.size.width,
                                    thisFrame.size.height);
            self.logicalResolution = CGSizeMake(thisFrame.size.width * backing.backingScaleFactor,
                                                thisFrame.size.height * backing.backingScaleFactor);
        }
    }

    return self;
}

- (CGSize)largestModePixelSizeForDisplayID:(CGDirectDisplayID)displayID {
    CGSize largest = CGSizeZero;

    NSArray *modes = (__bridge_transfer NSArray *)CGDisplayCopyAllDisplayModes(displayID, NULL);
    for (id m in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        CGSize size = CGSizeMake(CGDisplayModeGetPixelWidth(mode),
                                 CGDisplayModeGetPixelHeight(mode));
        if (size.width * size.height > largest.width * largest.height) {
            largest = size;
        }
    }

    // Fallback to the current mode if the panel advertises no enumerable modes.
    if (CGSizeEqualToSize(largest, CGSizeZero)) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (mode) {
            largest = CGSizeMake(CGDisplayModeGetPixelWidth(mode),
                                 CGDisplayModeGetPixelHeight(mode));
            CGDisplayModeRelease(mode);
        }
    }

    return largest;
}

- (nullable NSString *)edidNameForDisplayID:(CGDirectDisplayID)displayID {
    // `CoreDisplay_DisplayCreateInfoDictionary` is a private symbol that returns the
    // panel's EDID info keyed by display ID, so it works even for a mirrored secondary
    // that has no NSScreen. We resolve it via dlsym (rather than linking the private
    // CoreDisplay framework) and degrade gracefully if it is absent or sandbox-blocked.
    typedef CFDictionaryRef (*InfoDictFunc)(CGDirectDisplayID);
    static InfoDictFunc createInfo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createInfo = (InfoDictFunc)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    if (createInfo == NULL) {
        return nil;
    }

    NSDictionary *info = (__bridge_transfer NSDictionary *)createInfo(displayID);
    id productNames = info[@"DisplayProductName"];

    if ([productNames isKindOfClass:[NSString class]]) {
        return productNames;
    }
    if ([productNames isKindOfClass:[NSDictionary class]]) {
        // A locale -> name map. Prefer the current locale, then English, then anything.
        NSDictionary<NSString *, NSString *> *names = productNames;
        return names[[[NSLocale currentLocale] localeIdentifier]]
            ?: names[@"en_US"]
            ?: names.allValues.firstObject;
    }
    return nil;
}

+ (nullable NSScreen *)systemScreenForDisplayID:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        if ([number unsignedIntValue] == displayID) {
            return screen;
        }
    }
    return nil;
}

- (nullable NSScreen *)systemScreen {
    NSScreen *own = [TUCScreen systemScreenForDisplayID:(CGDirectDisplayID)self.id];
    if (own) {
        return own;
    }

    // Mirrored secondary: its content lives on the mirror master's NSScreen.
    CGDirectDisplayID master = CGDisplayMirrorsDisplay((CGDirectDisplayID)self.id);
    if (master != kCGNullDirectDisplay) {
        return [TUCScreen systemScreenForDisplayID:master];
    }
    return nil;
}


- (CGFloat)pixelsPerMM {
    // `frame` and `nativePhysicalSize` are both reported in the same (rotated) on-screen
    // orientation, so their widths line up directly — no manual swap needed.
    return self.frame.size.width / self.nativePhysicalSize.width;
}

- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint {
    CGPoint screenOrigin = self.frame.origin;
    CGSize screenSize = self.frame.size;


    CGPoint absLoc = CGPointMake(relativePoint.x * screenSize.width + screenOrigin.x,
                                 relativePoint.y * screenSize.height - screenOrigin.y);

    return absLoc;
}

- (CGPoint)convertGlassPointToContentPoint:(CGPoint)glassPoint {
    CGFloat glassAspect   = self.nativeResolution.width / self.nativeResolution.height;
    CGFloat contentAspect = self.frame.size.width / self.frame.size.height;
    if (glassAspect <= 0 || contentAspect <= 0) {
        return glassPoint;
    }

    // Aspect-fit the content into the glass: it fills one axis fully and is centred on the
    // other, the remaining strip being the black letterbox/pillarbox bars.
    CGFloat fracW = (contentAspect >= glassAspect) ? 1.0 : contentAspect / glassAspect;
    CGFloat fracH = (contentAspect >= glassAspect) ? glassAspect / contentAspect : 1.0;

    CGFloat x = (glassPoint.x - (1.0 - fracW) / 2.0) / fracW;
    CGFloat y = (glassPoint.y - (1.0 - fracH) / 2.0) / fracH;

    // A touch landing on a bar falls outside the content; snap it to the nearest edge.
    x = MAX(0.0, MIN(1.0, x));
    y = MAX(0.0, MIN(1.0, y));
    return CGPointMake(x, y);
}



- (NSString *)debugDescription {
    CGDirectDisplayID master = CGDisplayMirrorsDisplay((CGDirectDisplayID)self.id);
    NSString *mirror = (master != kCGNullDirectDisplay)
        ? [NSString stringWithFormat:@"mirrors #%u", master]
        : @"not mirrored";

    return [NSString stringWithFormat:
            @"<TUCScreen #%lu \"%@\"\n"
            "   uuid:     %@\n"
            "   native:   %.0f×%.0f px, %.0f×%.0f mm, rotation %.0f°\n"
            "   logical:  %.0f×%.0f px, %.2f px/mm\n"
            "   frame:    %@\n"
            "   mirror:   %@>",
            (unsigned long)self.id, self.name,
            self.uuid,
            self.nativeResolution.width, self.nativeResolution.height,
            self.nativePhysicalSize.width, self.nativePhysicalSize.height, self.rotation,
            self.logicalResolution.width, self.logicalResolution.height, [self pixelsPerMM],
            NSStringFromRect(self.frame),
            mirror];
}

+ (NSArray<TUCScreen *> *)allScreens {
    // Use the *online* display list rather than `[NSScreen screens]`: the latter only
    // returns active (drawable) displays and collapses a hardware-mirror set to its
    // master, so the mirrored panels would be invisible to us. The online list has one
    // entry per physically connected panel — exactly one TUCScreen each.
    uint32_t capacity = 0;
    CGGetOnlineDisplayList(0, NULL, &capacity);

    CGDirectDisplayID *displays = calloc(capacity, sizeof(CGDirectDisplayID));
    uint32_t returned = 0;
    CGGetOnlineDisplayList(capacity, displays, &returned);

    // `returned` can exceed `capacity` if a display is connected between the two calls;
    // never read past the buffer.
    uint32_t count = MIN(returned, capacity);

    // The primary display (origin) anchors the AppKit -> top-left coordinate flip.
    NSArray<NSScreen *> *nsScreens = [NSScreen screens];
    CGRect firstFrame = CGRectZero;
    if ([nsScreens count] > 0) {
        firstFrame = [nsScreens objectAtIndex:0].frame;
    }

    NSMutableArray<TUCScreen *> *myScreens = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        TUCScreen *e = [[TUCScreen alloc] initWithDisplayID:displays[i]
                                         frameOfFirstScreen:firstFrame];
        [myScreens addObject:e];
    }

    free(displays);
    return myScreens;
}

@end
