#import <TouchUpCore/TUCTouchInputManager.h>
#import <TouchUpCore/TUCCursorUtilities.h>
#import <TouchUpCore/HIDInterpreter.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>

// Exercise the production manager and cursor utilities without touching devices
// or posting OS input. Event objects remain real; only posting and reading the
// current pointer are intercepted so event coordinates and ordering are tested.
static NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *posted_events;
static CGPoint pointer_location;
static NSUInteger cursor_reads;
static NSUInteger closed_hid_managers;

void OpenHIDManager(void *delegate) { abort(); }
void CloseHIDManager(void) { closed_hid_managers++; }
void SetTouchDevicesSeized(bool seize) { abort(); }

static CGEventRef TestEventCreate(CGEventSourceRef source) CF_RETURNS_RETAINED {
  cursor_reads++;
  return CGEventCreateMouseEvent(source, kCGEventMouseMoved, pointer_location, kCGMouseButtonLeft);
}

static void TestEventPost(CGEventTapLocation tap, CGEventRef event) {
  CGEventType type = CGEventGetType(event);
  CGPoint location = CGEventGetLocation(event);
  [posted_events addObject:@{
    @"type": @(type), @"x": @(location.x), @"y": @(location.y),
    @"click_count": @(CGEventGetIntegerValueField(event, kCGMouseEventClickState)),
  }];
  switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDown:
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseDown:
    case kCGEventRightMouseUp:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
      pointer_location = location;
      break;
    default:
      break;
  }
}

#define CGEventCreate TestEventCreate
#define CGEventPost TestEventPost
#include "../TouchUpCore/TUCCursorUtilities.m"
#undef CGEventCreate
#undef CGEventPost

@interface PointerFixture : NSObject <TUCTouchDelegate>
@property TUCTouchInputManager *manager;
@property TUCScreen *screen;
@property TUCCursorAction touch_down_action;
@property TUCCursorAction tap_action;
@property TUCCursorAction drag_action;
- (void)updateContact:(CFIndex)contact_id x:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface;
- (void)report;
- (void)sampleX:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface;
@end

@implementation PointerFixture
- (instancetype)init {
  if ((self = [super init])) {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    [utils cancelMomentumScroll];
    [utils stopDraggingCursor];
    [utils stopMagnifying];
    posted_events = [NSMutableArray new];
    pointer_location = CGPointMake(-240, 125);
    cursor_reads = 0;
    closed_hid_managers = 0;

    self.screen = [TUCScreen new];
    self.screen.nativePhysicalSize = CGSizeMake(320, 160);
    self.screen.nativeResolution = CGSizeMake(1600, 800);
    self.screen.logicalResolution = self.screen.nativeResolution;
    self.screen.frame = CGRectMake(0, 0, 1600, 800);
    self.touch_down_action = TUCCursorActionMove;
    self.tap_action = TUCCursorActionClick;
    self.drag_action = TUCCursorActionScroll;
    self.manager = [TUCTouchInputManager new];
    self.manager.delegate = self;
    self.manager.holdDuration = DBL_MAX;
    self.manager.restoreCursorAfterTouch = YES;
    TouchInputManagerDidConnectTouchscreen((__bridge void *)self.manager, 1);
  }
  return self;
}

- (void)updateContact:(CFIndex)contact_id x:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface {
  TouchInputManagerUpdateTouchPosition((__bridge void *)self.manager, 1, contact_id,
    0.5 + x_mm / 320, 0.5 + y_mm / 160, on_surface, true);
}
- (void)report {
  TouchInputManagerDidProcessReport((__bridge void *)self.manager, 1);
}
- (void)sampleX:(CGFloat)x_mm y:(CGFloat)y_mm onSurface:(BOOL)on_surface {
  [self updateContact:7 x:x_mm y:y_mm onSurface:on_surface];
  [self report];
}
- (void)touchesDidChange {}
- (void)touchscreenDidConnectWithLocationID:(uint32_t)location_id {}
- (void)touchscreenDidDisconnectWithLocationID:(uint32_t)location_id {}
- (TUCScreen *)touchscreenForLocationID:(uint32_t)location_id { return self.screen; }
- (CGFloat)digitizerRotationForLocationID:(uint32_t)location_id { return 0; }
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
  switch (gesture) {
    case TUCCursorGestureTouchDown: return self.touch_down_action;
    case TUCCursorGestureTap: return self.tap_action;
    case TUCCursorGestureDrag: return self.drag_action;
    case TUCCursorGestureHoldAndDrag: return TUCCursorActionDrag;
    case TUCCursorGestureTapSecondFinger: return TUCCursorActionSecondaryClick;
    case TUCCursorGesturePinch: return TUCCursorActionMagnify;
    default: return TUCCursorActionNone;
  }
}
@end

static NSUInteger checks;
static NSUInteger failures;
static const CGPoint original_location = { -240, 125 };

static void check(BOOL passed, NSString *description) {
  checks++;
  if (!passed) failures++;
  printf("%s %s\n", passed ? "PASS" : "FAIL", description.UTF8String);
}

static CGPoint eventLocation(NSDictionary<NSString *, NSNumber *> *event) {
  return CGPointMake(event[@"x"].doubleValue, event[@"y"].doubleValue);
}

static BOOL eventIs(NSDictionary<NSString *, NSNumber *> *event, CGEventType type, CGPoint location) {
  return event && event[@"type"].unsignedIntValue == type
    && CGPointEqualToPoint(eventLocation(event), location);
}

static NSUInteger eventCount(CGEventType type) {
  NSUInteger count = 0;
  for (NSDictionary<NSString *, NSNumber *> *event in posted_events) {
    if (event[@"type"].unsignedIntValue == type) count++;
  }
  return count;
}

static NSUInteger restoreCount(void) {
  NSUInteger count = 0;
  for (NSDictionary<NSString *, NSNumber *> *event in posted_events) {
    if (eventIs(event, kCGEventMouseMoved, original_location)) count++;
  }
  return count;
}

static void testTap(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  check(cursor_reads == 1 && eventIs(posted_events.firstObject, kCGEventMouseMoved, CGPointMake(800, 400)),
    @"touch-down saves the original pointer before moving to the touched location");
  check(restoreCount() == 0, @"pointer stays at the touch target while a finger is down");
  [fixture sampleX:0 y:0 onSurface:NO];
  check(posted_events.count == 4
    && eventIs(posted_events[1], kCGEventLeftMouseDown, CGPointMake(800, 400))
    && eventIs(posted_events[2], kCGEventLeftMouseUp, CGPointMake(800, 400))
    && eventIs(posted_events[3], kCGEventMouseMoved, original_location),
    @"tap posts mouse-down and mouse-up at the touch target before restoring the pointer");
  check(CGPointEqualToPoint(pointer_location, original_location), @"tap restores a pointer on another display");
  NSUInteger event_count = posted_events.count;
  [fixture report];
  [fixture report];
  check(posted_events.count == event_count, @"later empty reports cannot repeat a tap or restoration");
  [fixture sampleX:0 y:0 onSurface:NO];
  check(posted_events.count == event_count, @"a repeated lift-off cannot create a new tap or restoration");

  CGPoint next_origin = CGPointMake(-600, 200);
  pointer_location = next_origin;
  [fixture sampleX:10 y:10 onSurface:YES];
  [fixture sampleX:10 y:10 onSurface:NO];
  check(CGPointEqualToPoint(pointer_location, next_origin) && cursor_reads == 2,
    @"a new touch session captures the pointer's new location");
}

static void testDelayedMouseOutput(void) {
  PointerFixture *fixture = [PointerFixture new];
  fixture.touch_down_action = TUCCursorActionNone;
  [fixture sampleX:0 y:0 onSurface:YES];
  check(cursor_reads == 0 && posted_events.count == 0, @"an action mapped to None does not capture the pointer");
  CGPoint latest_origin = CGPointMake(-400, 300);
  pointer_location = latest_origin;
  [fixture sampleX:0 y:0 onSurface:NO];
  check(cursor_reads == 1 && posted_events.count == 3
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, latest_origin),
    @"tap-only mapping captures immediately before the click and restores after mouse-up");
}

static void testDisabledOutput(void) {
  PointerFixture *fixture = [PointerFixture new];
  fixture.manager.postMouseEvents = NO;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(cursor_reads == 0 && posted_events.count == 0, @"debug-only touches neither capture nor restore the pointer");

  fixture = [PointerFixture new];
  fixture.manager.restoreCursorAfterTouch = NO;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(cursor_reads == 0 && posted_events.count == 3 && restoreCount() == 0
    && CGPointEqualToPoint(pointer_location, CGPointMake(800, 400)),
    @"turning restoration off preserves ordinary pointer-following behavior");

  fixture = [PointerFixture new];
  fixture.touch_down_action = TUCCursorActionNone;
  fixture.tap_action = TUCCursorActionNone;
  fixture.drag_action = TUCCursorActionNone;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(cursor_reads == 0 && posted_events.count == 0, @"a touch with no mouse actions never saves or restores a position");
}

static void testMultipleFingers(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  [fixture report];
  check(cursor_reads == 1 && restoreCount() == 0, @"adding another finger does not overwrite the saved pointer");
  [fixture updateContact:7 x:0 y:0 onSurface:NO];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  [fixture report];
  check(restoreCount() == 0, @"lifting the primary finger does not restore while another finger remains");
  [fixture updateContact:8 x:10 y:0 onSurface:NO];
  [fixture report];
  check(restoreCount() == 1 && CGPointEqualToPoint(pointer_location, original_location),
    @"the final finger restores the original pre-session pointer exactly once");
  NSUInteger event_count = posted_events.count;
  [fixture report];
  check(posted_events.count == event_count, @"an empty report after multiple fingers adds no click or restore");

  fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  [fixture report];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:NO];
  [fixture report];
  check(eventCount(kCGEventRightMouseUp) == 1 && restoreCount() == 0,
    @"secondary click completes without restoring while the first finger remains");
  [fixture sampleX:0 y:0 onSurface:NO];
  check(restoreCount() == 1, @"secondary-click session restores only after the final lift-off");
}

static void testPinch(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  [fixture report];
  [fixture updateContact:7 x:-4 y:0 onSurface:YES];
  [fixture updateContact:8 x:14 y:0 onSurface:YES];
  [fixture report];
  check(eventCount(29) > 0 && restoreCount() == 0,
    @"pinch posts a gesture at its touch target while retaining the saved pointer");
  [fixture updateContact:7 x:-4 y:0 onSurface:NO];
  [fixture updateContact:8 x:14 y:0 onSurface:YES];
  [fixture report];
  check(restoreCount() == 0, @"ending the primary pinch contact leaves the pointer at the gesture target");
  [fixture updateContact:8 x:14 y:0 onSurface:NO];
  [fixture report];
  check(restoreCount() == 1 && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location)
    && eventCount(kCGEventLeftMouseDown) == 0,
    @"pinch restores after the last contact without synthesizing a tap");
}

static void beginHeldDrag(PointerFixture *fixture) {
  [fixture sampleX:0 y:0 onSurface:YES];
  fixture.manager.holdDuration = 0.1;
  [fixture.manager setValue:[NSDate dateWithTimeIntervalSince1970:0] forKey:@"cursorTouchStationarySinceDate"];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:4 y:0 onSurface:YES];
  [fixture sampleX:8 y:0 onSurface:YES];
}

static void testDrag(void) {
  PointerFixture *fixture = [PointerFixture new];
  beginHeldDrag(fixture);
  check(eventCount(kCGEventLeftMouseDown) == 1 && eventCount(kCGEventLeftMouseDragged) == 1,
    @"held touch begins a real drag through the production cursor utilities");
  [fixture sampleX:8 y:0 onSurface:NO];
  NSUInteger count = posted_events.count;
  check(count >= 2 && eventIs(posted_events[count - 2], kCGEventLeftMouseUp, CGPointMake(840, 400))
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
    @"drag releases the button at the drag target before restoring the pointer");
  check(eventCount(kCGEventLeftMouseDown) == 1 && restoreCount() == 1,
    @"finishing a drag adds neither a tap nor an extra restoration");
}

static void testDragReleaseTarget(void) {
  __unused PointerFixture *fixture = [PointerFixture new];
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  [utils dragCursorTo:CGPointMake(500, 300) phase:NSTouchPhaseBegan];
  [utils dragCursorTo:CGPointMake(600, 320) phase:NSTouchPhaseMoved];
  pointer_location = CGPointMake(50, 50);
  [utils stopDraggingCursor];
  check(eventIs(posted_events.lastObject, kCGEventLeftMouseUp, CGPointMake(600, 320)),
    @"drag release uses the last touch-generated drag position even if the pointer moved elsewhere");
}

static void testInterruptedSessions(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture report];
  check(restoreCount() == 1 && eventCount(kCGEventLeftMouseDown) == 0,
    @"a missing contact cancels the touch and restores without clicking");
  [fixture report];
  check(restoreCount() == 1, @"repeated cancellation cannot restore a second time");

  fixture = [PointerFixture new];
  beginHeldDrag(fixture);
  TouchInputManagerDidDisconnectTouchscreen((__bridge void *)fixture.manager, 1);
  NSUInteger count = posted_events.count;
  check(count >= 2 && eventIs(posted_events[count - 2], kCGEventLeftMouseUp, CGPointMake(840, 400))
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
    @"disconnect releases an active drag before restoring the pointer");
  [fixture report];
  check(restoreCount() == 1, @"a report after disconnect cannot restore twice");

  fixture = [PointerFixture new];
  beginHeldDrag(fixture);
  [fixture.manager stop];
  count = posted_events.count;
  check(closed_hid_managers == 1 && count >= 2
    && eventIs(posted_events[count - 2], kCGEventLeftMouseUp, CGPointMake(840, 400))
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
    @"stopping input closes HID and releases the drag before restoring");

  fixture = [PointerFixture new];
  beginHeldDrag(fixture);
  fixture.manager.postMouseEvents = NO;
  count = posted_events.count;
  check(count >= 2 && eventIs(posted_events[count - 2], kCGEventLeftMouseUp, CGPointMake(840, 400))
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
    @"disabling mouse output releases the drag and restores immediately");
  [fixture sampleX:8 y:0 onSurface:NO];
  check(posted_events.count == count, @"lift-off after disabling output adds no mouse events");
}

static void testScrollMomentum(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:4 y:0 onSurface:YES];
  [fixture sampleX:8 y:0 onSurface:YES];
  CGPoint scroll_target = eventLocation(posted_events.lastObject);
  check(eventCount(kCGEventScrollWheel) == 2 && restoreCount() == 0,
    @"scrolling posts wheel events before restoring any pointer");
  [fixture sampleX:8 y:0 onSurface:NO];
  check(restoreCount() == 1 && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
    @"scroll lift-off restores the pointer after the final touch action");
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  NSTimer *timer = [utils valueForKey:@"momentumScrollTimer"];
  check(timer.isValid, @"restoring the pointer preserves scroll momentum");
  [utils updateMomentumScroll];
  check(eventIs(posted_events.lastObject, kCGEventScrollWheel, scroll_target)
    && CGPointEqualToPoint(pointer_location, original_location),
    @"momentum stays at the touch scroll target after the pointer is restored elsewhere");
  TouchInputManagerDidDisconnectTouchscreen((__bridge void *)fixture.manager, 1);
  check(!timer.isValid && restoreCount() == 1,
    @"disconnect after lift-off cancels momentum without repeating restoration");
}

int main(void) {
  @autoreleasepool {
    check(![TUCTouchInputManager new].restoreCursorAfterTouch, @"core restoration defaults to opt-in");
    testTap();
    testDelayedMouseOutput();
    testDisabledOutput();
    testMultipleFingers();
    testPinch();
    testDrag();
    testDragReleaseTarget();
    testInterruptedSessions();
    testScrollMomentum();
    printf("\n%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
