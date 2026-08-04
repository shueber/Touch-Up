//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TUCCursorUtilities : NSObject

+ (instancetype)sharedInstance;


/**
 Radius, in screen points, within which a follow-up click continues the current click
 sequence instead of starting a new one. Callers own the conversion from a physical
 distance, since points per millimetre differ per screen.

 A non-positive value means no two clicks are ever close enough to form a sequence, i.e. it
 disables double clicking.
 */
@property CGFloat doubleClickTolerance;

- (CGPoint)currentCursorLocation;

- (void)bringWindowToFrontAt:(CGPoint)aLocation;

- (void)moveCursorTo:(CGPoint)aLocation;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;


@end

NS_ASSUME_NONNULL_END
