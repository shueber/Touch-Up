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


@property CGFloat doubleClickTolerance;

- (CGPoint)currentCursorLocation;

- (void)bringWindowToFrontAt:(CGPoint)aLocation;

- (void)moveCursorTo:(CGPoint)aLocation;
/// Posts a pointer move in order with queued touch events. Call after momentum ends.
- (void)restoreCursorTo:(CGPoint)aLocation;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;
- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase atLocation:(CGPoint)location;
/// Runs immediately if idle, or once momentum finishes. Cancellation discards it.
- (void)finishMomentumScrollWithCompletion:(void (^)(void))completion;
- (void)cancelMomentumScroll;

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;


@end

NS_ASSUME_NONNULL_END
