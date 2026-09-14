#import <TouchUpCore/TUCTouchInputManager.h>
#import <TouchUpCore/TUCCursorUtilities.h>
#import <TouchUpCore/HIDInterpreter.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>

// Compile the production input manager, touch model, and screen transforms. Replace
// only the hardware entry points and mouse output: this executable never opens a
// digitizer, requests permissions, or injects a system event.
void OpenHIDManager(void *delegate) { abort(); }
void CloseHIDManager(void) { abort(); }
void SetTouchDevicesSeized(bool seize) { abort(); }

@implementation TUCCursorUtilities
+ (instancetype)sharedInstance {
  static TUCCursorUtilities *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [TUCCursorUtilities new]; });
  return instance;
}
- (CGPoint)currentCursorLocation { abort(); }
- (void)bringWindowToFrontAt:(CGPoint)location { abort(); }
- (void)moveCursorTo:(CGPoint)location { abort(); }
- (void)restoreCursorTo:(CGPoint)location { abort(); }
- (void)performClickAt:(CGPoint)location { abort(); }
- (void)performSecondaryClickAt:(CGPoint)location { abort(); }
- (void)dragCursorTo:(CGPoint)location phase:(NSTouchPhase)phase { abort(); }
- (void)stopDraggingCursor {}
- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase { abort(); }
- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase atLocation:(CGPoint)location { abort(); }
- (void)cancelMomentumScroll {}
- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2 { abort(); }
- (void)stopMagnifying {}
@end

@interface TUCTouchInputManager (GestureRegressionAccess)
- (void)performMouseEventForGesture:(TUCCursorGesture)gesture;
@end

@interface GestureRecorder : TUCTouchInputManager
@property NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *events;
- (NSUInteger)countGesture:(TUCCursorGesture)gesture phase:(NSTouchPhase)phase;
@end

@implementation GestureRecorder
- (instancetype)init {
  if ((self = [super init])) {
    self.events = [NSMutableArray new];
    // Ordinary tests must never depend on how long compilation or execution takes.
    self.holdDuration = DBL_MAX;
  }
  return self;
}

- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
  TUCTouch *cursor = [self valueForKey:@"cursorTouch"];
  [self.events addObject:@{ @"gesture": @(gesture), @"phase": @(cursor.phase) }];
}

- (NSUInteger)countGesture:(TUCCursorGesture)gesture phase:(NSTouchPhase)phase {
  NSUInteger count = 0;
  for (NSDictionary<NSString *, NSNumber *> *event in self.events) {
    if (event[@"gesture"].unsignedIntegerValue == gesture
        && (phase == NSTouchPhaseAny || event[@"phase"].unsignedIntegerValue == phase)) {
      count++;
    }
  }
  return count;
}
@end

@interface GestureFixture : NSObject <TUCTouchDelegate>
@property GestureRecorder *manager;
@property TUCScreen *screen;
@property CGFloat digitizerRotation;
@property CGSize digitizerPhysicalSize;
- (instancetype)initWithRotation:(CGFloat)rotation;
- (void)updateContact:(CFIndex)contact_id x:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface;
- (void)sampleX:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface;
- (BOOL)isSingleTap;
- (BOOL)isScrollWithoutTap;
@end

@implementation GestureFixture
- (instancetype)initWithRotation:(CGFloat)rotation {
  if ((self = [super init])) {
    self.screen = [TUCScreen new];
    self.screen.rotation = rotation;
    BOOL portrait = rotation == 90 || rotation == 270;
    self.screen.nativePhysicalSize = portrait ? CGSizeMake(160, 320) : CGSizeMake(320, 160);
    self.screen.nativeResolution = portrait ? CGSizeMake(800, 1600) : CGSizeMake(1600, 800);
    self.screen.frame = (CGRect){ CGPointZero, self.screen.nativeResolution };
    self.screen.logicalResolution = self.screen.nativeResolution;
    self.digitizerPhysicalSize = CGSizeMake(320, 160);
    self.manager = [GestureRecorder new];
    self.manager.delegate = self;
    TouchInputManagerDidConnectTouchscreen((__bridge void *)self.manager, 1);
  }
  return self;
}

- (void)updateContact:(CFIndex)contact_id x:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface {
  // The raw hardware axes are independent of the current desktop rotation.
  TouchInputManagerUpdateTouchPosition((__bridge void *)self.manager, 1, contact_id,
    0.5 + x_mm / self.digitizerPhysicalSize.width,
    0.5 + y_mm / self.digitizerPhysicalSize.height, on_surface, true);
}

- (void)sampleX:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface {
  [self updateContact:7 x:x_mm y:y_mm onSurface:on_surface];
  TouchInputManagerDidProcessReport((__bridge void *)self.manager, 1);
}

- (BOOL)isSingleTap {
  return [self.manager countGesture:TUCCursorGestureTap phase:NSTouchPhaseEnded] == 1
    && [self.manager countGesture:TUCCursorGestureDrag phase:NSTouchPhaseAny] == 0
    && [self.manager countGesture:TUCCursorGestureHoldAndDrag phase:NSTouchPhaseAny] == 0;
}

- (BOOL)isScrollWithoutTap {
  return [self.manager countGesture:TUCCursorGestureDrag phase:NSTouchPhaseMoved] > 0
    && [self.manager countGesture:TUCCursorGestureTap phase:NSTouchPhaseAny] == 0
    && [self.manager countGesture:TUCCursorGestureHoldAndDrag phase:NSTouchPhaseAny] == 0;
}

- (void)touchesDidChange {}
- (void)touchscreenDidConnectWithLocationID:(uint32_t)locationID {}
- (void)touchscreenDidDisconnectWithLocationID:(uint32_t)locationID {}
- (TUCScreen *)touchscreenForLocationID:(uint32_t)locationID { return self.screen; }
- (CGFloat)digitizerRotationForLocationID:(uint32_t)locationID { return self.digitizerRotation; }
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
  switch (gesture) {
    case TUCCursorGestureTap: return TUCCursorActionClick;
    case TUCCursorGestureDrag: return TUCCursorActionScroll;
    case TUCCursorGestureHoldAndDrag: return TUCCursorActionDrag;
    default: return TUCCursorActionNone;
  }
}
@end

static NSUInteger checks;
static NSUInteger failures;

static void check(BOOL passed, NSString *description) {
  checks++;
  if (!passed) failures++;
  printf("%s %s\n", passed ? "PASS" : "FAIL", description.UTF8String);
}

static void testTapJitter(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0.4 y:0.2 onSurface:YES];
  [fixture sampleX:-0.6 y:-0.4 onSurface:YES];
  [fixture sampleX:0.8 y:0.5 onSurface:YES];
  check(fixture.manager.events.count == 1,
    @"finger jitter emits no movement gesture before lift-off");
  [fixture sampleX:0.5 y:0.3 onSurface:NO];
  check(fixture.isSingleTap, @"sub-2 mm finger jitter produces one tap and no scroll");
}

static void testAccumulatedMotion(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  for (NSUInteger step = 1; step <= 39; step++) {
    [fixture sampleX:step * 0.05 y:0 onSurface:YES];
  }
  check(fixture.manager.events.count == 1,
    @"tiny steps remain a possible tap below 2 mm from touch-down");
  [fixture sampleX:2.05 y:0 onSurface:YES];
  check([fixture.manager countGesture:TUCCursorGestureDrag phase:NSTouchPhaseMoved] == 1,
    @"tiny steps become scroll after crossing 2 mm from touch-down");
  [fixture sampleX:2.10 y:0 onSurface:YES];
  check([fixture.manager countGesture:TUCCursorGestureDrag phase:NSTouchPhaseMoved] == 2,
    @"a recognized scroll continues with nonzero steps smaller than 0.1 mm");
  [fixture sampleX:2.05 y:0 onSurface:NO];
  check(fixture.isScrollWithoutTap,
    @"a slow scroll never becomes a click when the finger lifts");
}

static void testReturnToOrigin(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:3 y:0 onSurface:YES];
  [fixture sampleX:0.5 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(fixture.isScrollWithoutTap,
    @"returning to touch-down after scrolling cannot restore tap eligibility");
}

static void testRepeatedJitter(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  for (NSUInteger step = 0; step < 20; step++) {
    [fixture sampleX:step % 2 == 0 ? 1.5 : -1.5 y:0 onSurface:YES];
  }
  [fixture sampleX:0 y:0 onSurface:NO];
  check(fixture.isSingleTap,
    @"back-and-forth jitter uses maximum displacement, not total path length");
}

static void testPhysicalAxesAndRotation(void) {
  for (NSNumber *angle in @[@0, @90, @180, @270]) {
    GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:angle.doubleValue];
    [fixture sampleX:0 y:0 onSurface:YES];
    [fixture sampleX:0 y:1.5 onSurface:YES];
    [fixture sampleX:0 y:1.5 onSurface:NO];
    check(fixture.isSingleTap, [NSString stringWithFormat:
      @"1.5 mm vertical jitter remains a tap on non-square glass rotated %@°", angle]);

    fixture = [[GestureFixture alloc] initWithRotation:angle.doubleValue];
    [fixture sampleX:0 y:0 onSurface:YES];
    [fixture sampleX:2.5 y:0 onSurface:YES];
    [fixture sampleX:2.5 y:0 onSurface:NO];
    check(fixture.isScrollWithoutTap, [NSString stringWithFormat:
      @"2.5 mm horizontal movement scrolls on non-square glass rotated %@°", angle]);
  }

  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  fixture.digitizerRotation = 90;
  fixture.digitizerPhysicalSize = CGSizeMake(160, 320);
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:1.5 onSurface:YES];
  [fixture sampleX:0 y:1.5 onSurface:NO];
  check(fixture.isSingleTap, @"digitizer calibration rotation preserves physical tap tolerance");
}

static void testLetterboxing(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  fixture.screen.frame = CGRectMake(0, 0, 800, 800);
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:1.5 y:0 onSurface:YES];
  [fixture sampleX:1.5 y:0 onSurface:NO];
  check(fixture.isSingleTap,
    @"letterboxed content does not magnify 1.5 mm glass jitter into scrolling");
}

static void testDiagonalBoundary(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:1.4 y:1.4 onSurface:YES];
  [fixture sampleX:1.4 y:1.4 onSurface:NO];
  check(fixture.isSingleTap, @"diagonal movement just below 2 mm remains a tap");

  fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:1.5 y:1.5 onSurface:YES];
  [fixture sampleX:1.5 y:1.5 onSurface:NO];
  check(fixture.isScrollWithoutTap, @"diagonal movement above 2 mm starts scrolling");
}

static void testLiftOffJitter(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:1.5 y:0 onSurface:NO];
  check(fixture.isSingleTap, @"touch-down and jittered lift-off alone produce one tap");

  fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:20 y:10 onSurface:NO];
  check(fixture.isSingleTap, @"coordinates reported only after lift-off do not start a scroll");
}

static void testHoldAndDrag(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0.4 y:0.2 onSurface:YES];
  fixture.manager.holdDuration = 0.08;
  [fixture.manager setValue:[NSDate dateWithTimeIntervalSinceNow:-1]
    forKey:@"cursorTouchStationarySinceDate"];
  [fixture sampleX:0.42 y:0.21 onSurface:YES];
  [fixture sampleX:3 y:0.3 onSurface:YES];
  [fixture sampleX:3 y:0.3 onSurface:NO];
  check([fixture.manager countGesture:TUCCursorGestureHoldAndDrag phase:NSTouchPhaseMoved] == 1
      && [fixture.manager countGesture:TUCCursorGestureHoldAndDrag phase:NSTouchPhaseEnded] == 1
      && [fixture.manager countGesture:TUCCursorGestureDrag phase:NSTouchPhaseAny] == 0
      && [fixture.manager countGesture:TUCCursorGestureTap phase:NSTouchPhaseAny] == 0,
    @"holding through sub-0.1 mm jitter permits hold-and-drag without scroll or tap");
}

static void testHoldAnchor(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  NSDate *old_date = [NSDate dateWithTimeIntervalSinceNow:-1];
  [fixture.manager setValue:old_date forKey:@"cursorTouchStationarySinceDate"];
  // Keep hold disabled while checking the timer, so the result depends only on
  // displacement across the samples, never the speed of the test machine.
  [fixture sampleX:0.06 y:0 onSurface:YES];
  [fixture sampleX:0.12 y:0 onSurface:YES];
  NSDate *current_date = [fixture.manager valueForKey:@"cursorTouchStationarySinceDate"];
  check(current_date != nil && [current_date compare:old_date] == NSOrderedDescending,
    @"slow sub-0.1 mm steps reset the hold timer after leaving its stationary anchor");
}

static void testConfiguredTolerance(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  // Binary-exact distances avoid accidental floating-point boundary ambiguity.
  fixture.screen.nativePhysicalSize = CGSizeMake(256, 128);
  fixture.digitizerPhysicalSize = fixture.screen.nativePhysicalSize;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:2 y:0 onSurface:YES];
  [fixture sampleX:2 y:0 onSurface:NO];
  check(fixture.isSingleTap, @"movement exactly at the 2 mm tolerance remains a tap");

  fixture = [[GestureFixture alloc] initWithRotation:0];
  fixture.manager.tapMovementTolerance = 4;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:3 y:0 onSurface:YES];
  [fixture sampleX:3 y:0 onSurface:NO];
  check(fixture.isSingleTap, @"a configured 4 mm tolerance accepts a 3 mm tap");
}

static void testCancellation(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0.8 y:0.3 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check(fixture.manager.events.count == 1,
    @"a missing contact cancels the gesture without generating a tap or scroll");
}

static void testNextGesture(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:3 y:0 onSurface:YES];
  [fixture sampleX:3 y:0 onSurface:NO];
  [fixture.manager.events removeAllObjects];
  [fixture sampleX:30 y:20 onSurface:YES];
  [fixture sampleX:30.5 y:20.5 onSurface:YES];
  [fixture sampleX:30.5 y:20.5 onSurface:NO];
  check(fixture.isSingleTap, @"the next touch resets its origin and tap eligibility after a scroll");
}

static void testMultitouch(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture updateContact:7 x:-10 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  [fixture updateContact:7 x:-10.5 y:0 onSurface:YES];
  [fixture updateContact:8 x:10.5 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  [fixture updateContact:7 x:-10.5 y:0 onSurface:NO];
  [fixture updateContact:8 x:10.5 y:0 onSurface:NO];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGesturePinch phase:NSTouchPhaseAny] > 0
      && [fixture.manager countGesture:TUCCursorGestureTap phase:NSTouchPhaseAny] == 0,
    @"small opposing two-finger movement still pinches and suppresses a primary tap");

  fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  [fixture updateContact:7 x:0.5 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:NO];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGestureTapSecondFinger phase:NSTouchPhaseAny] == 1,
    @"a second-finger tap still works while the primary finger stays within tap tolerance");
}

static void testPinchJitter(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture updateContact:7 x:-10 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  [fixture updateContact:7 x:-10.02 y:0 onSurface:YES];
  [fixture updateContact:8 x:10.02 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGesturePinch phase:NSTouchPhaseAny] == 0,
    @"opposing 0.02 mm jitter from two resting fingers does not start a pinch");
  [fixture updateContact:7 x:-10.02 y:0 onSurface:YES];
  [fixture updateContact:8 x:10.02 y:0 onSurface:NO];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGesturePinch phase:NSTouchPhaseAny] == 0
      && [fixture.manager countGesture:TUCCursorGestureTapSecondFinger phase:NSTouchPhaseAny] == 1,
    @"lifting a second finger after opposing jitter still produces a secondary tap");

  fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture updateContact:7 x:-10 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  [fixture updateContact:7 x:-10.5 y:0 onSurface:YES];
  [fixture updateContact:8 x:10.02 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGesturePinch phase:NSTouchPhaseAny] == 0,
    @"pinch requires intentional movement from both fingers, not one plus jitter");
}

static void testNewSecondaryContact(void) {
  GestureFixture *fixture = [[GestureFixture alloc] initWithRotation:0];
  [fixture sampleX:-10 y:0 onSurface:YES];
  [fixture updateContact:7 x:-10.5 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGesturePinch phase:NSTouchPhaseAny] == 0,
    @"a new second contact has no movement trajectory and cannot initiate a pinch");
  [fixture updateContact:7 x:-10.5 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:NO];
  TouchInputManagerDidProcessReport((__bridge void *)fixture.manager, 1);
  check([fixture.manager countGesture:TUCCursorGestureTapSecondFinger phase:NSTouchPhaseAny] == 1,
    @"a new second contact can still tap while the primary finger moves slightly");
}

int main(void) {
  @autoreleasepool {
    testTapJitter();
    testAccumulatedMotion();
    testReturnToOrigin();
    testRepeatedJitter();
    testPhysicalAxesAndRotation();
    testLetterboxing();
    testDiagonalBoundary();
    testLiftOffJitter();
    testHoldAndDrag();
    testHoldAnchor();
    testConfiguredTolerance();
    testCancellation();
    testNextGesture();
    testMultitouch();
    testPinchJitter();
    testNewSecondaryContact();
    printf("\n%lu gesture regression checks, %lu failures\n",
      (unsigned long)checks, (unsigned long)failures);
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
