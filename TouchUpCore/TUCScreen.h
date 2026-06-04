//
//  TUCScreen.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/**
 `TUCScreen` describes one physically connected display panel.

 Unlike `NSScreen`, a `TUCScreen` exists for every connected panel — including the
 individual members of a hardware-mirror set, which AppKit collapses into a single
 `NSScreen`. The list therefore always has exactly one entry per panel.

 Properties are split into two groups:

 - **native**: fixed characteristics of the hardware as it was built. They never change
   when the user rotates the display in System Settings.
 - **logical**: the current desktop arrangement and rotation, taken from the matching
   `NSScreen`. For a mirrored secondary panel (which has no `NSScreen` of its own) these
   describe the mirror master's content that the panel is showing.
 */
@interface TUCScreen : NSObject

#pragma mark Identity

/// The `CGDirectDisplayID` of the panel.
@property NSUInteger id;
/// Stable across launches and screen rearrangements; unique per physical panel.
@property (strong) NSString *uuid;
/// Human-readable display name.
@property (strong) NSString *name;

#pragma mark Native hardware (this panel's own EDID, mirror-independent)

/// This panel's own pixel grid, e.g. 3840 × 2160. Unlike `logicalResolution` it is the
/// panel's own hardware even while mirroring, but its width/height swap with `rotation`.
@property CGSize nativeResolution;
/// This panel's own physical size in millimetres, e.g. 600 × 340. Mirror-independent,
/// but its width/height swap with `rotation`.
@property CGSize nativePhysicalSize;

#pragma mark Logical layout (reflects the current arrangement & rotation)

/// Logical rotation in degrees: 0 / 90 / 180 / 270.
@property CGFloat rotation;
/// Framebuffer pixel resolution in the current orientation (points × backing scale).
@property CGSize logicalResolution;
/// Placement of the panel in the global, top-left-origin layout space (points).
/// `frame.size` is the logical (rotated) size.
@property CGRect frame;

#pragma mark -

/// Points per millimetre in the current on-screen orientation.
- (CGFloat)pixelsPerMM;
- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint;

/// Maps a point normalised over the full panel glass (in this screen's orientation) to one
/// normalised over the letterboxed content rectangle macOS actually draws
/// The result is clamped to [0,1]; touches on the bars snap to the edge.
- (CGPoint)convertGlassPointToContentPoint:(CGPoint)glassPoint;

/// The `NSScreen` backing this panel. For a mirrored secondary this is the mirror
/// master's `NSScreen`, since that is where the panel's content lives.
- (nullable NSScreen *)systemScreen;

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
               frameOfFirstScreen:(CGRect)firstFrame;

+ (NSArray<TUCScreen *> *)allScreens;

@end

NS_ASSUME_NONNULL_END
