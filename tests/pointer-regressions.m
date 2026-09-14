#import <TouchUpCore/TUCTouchInputManager.h>
#import <TouchUpCore/TUCCursorUtilities.h>
#import <TouchUpCore/HIDInterpreter.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>

// Real event objects, with controllable delivery and a simulated pointer observer.
static NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *posted_events;
static NSMutableArray<NSValue *> *pending_events;
static CGPoint pointer_location;
static NSUInteger cursor_reads;
static NSUInteger closed_hid_managers;
static BOOL defer_event_delivery;
static CGEventTapCallBack pointer_callback;
static void *pointer_callback_context;
static CGEventMask pointer_event_mask;
static CGEventTapLocation pointer_tap_location;
static CGEventTapOptions pointer_tap_options;

void OpenHIDManager(void *delegate) { abort(); }
void CloseHIDManager(void) { closed_hid_managers++; }
void SetTouchDevicesSeized(bool seize) { abort(); }

static CGEventRef TestEventCreate(CGEventSourceRef source) CF_RETURNS_RETAINED {
  cursor_reads++;
  return CGEventCreateMouseEvent(source, kCGEventMouseMoved, pointer_location, kCGMouseButtonLeft);
}

static void applyPointerEvent(CGEventRef event) {
  CGEventType type = CGEventGetType(event);
  CGPoint location = CGEventGetLocation(event);
  switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDown:
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseDown:
    case kCGEventRightMouseUp:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDown:
    case kCGEventOtherMouseUp:
    case kCGEventOtherMouseDragged:
    case kCGEventScrollWheel:
      pointer_location = location;
      break;
    default:
      break;
  }
}

static void observePointerEvent(CGEventRef event) {
  CGEventType type = CGEventGetType(event);
  if (pointer_callback && (pointer_event_mask & CGEventMaskBit(type))) {
    pointer_callback(NULL, type, event, pointer_callback_context);
  }
}

static void deliverPointerEvent(CGEventRef event) {
  applyPointerEvent(event);
  observePointerEvent(event);
}

static CGEventRef takeNextPostedEvent(void) CF_RETURNS_RETAINED {
  CGEventRef event = pending_events.firstObject.pointerValue;
  [pending_events removeObjectAtIndex:0];
  return event;
}

static void deliverNextPostedEvent(void) {
  CGEventRef event = takeNextPostedEvent();
  deliverPointerEvent(event);
  CFRelease(event);
}

static void deliverAllPostedEvents(void) {
  while (pending_events.count) deliverNextPostedEvent();
}

static void movePhysicalPointer(CGPoint location) {
  CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, location, kCGMouseButtonLeft);
  CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0);
  deliverPointerEvent(event);
  CFRelease(event);
}

static void TestEventPost(CGEventTapLocation tap, CGEventRef event) {
  CGPoint location = CGEventGetLocation(event);
  [posted_events addObject:@{
    @"type": @(CGEventGetType(event)), @"x": @(location.x), @"y": @(location.y),
    @"click_count": @(CGEventGetIntegerValueField(event, kCGMouseEventClickState)),
    @"event_id": @(CGEventGetIntegerValueField(event, kCGEventSourceUserData)),
  }];
  if (defer_event_delivery) {
    [pending_events addObject:[NSValue valueWithPointer:CGEventCreateCopy(event)]];
  } else {
    deliverPointerEvent(event);
  }
}

static void TestMachPortCallback(CFMachPortRef port, void *message, CFIndex size, void *context) {}

static CFMachPortRef TestEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place,
    CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback,
    void *context) CF_RETURNS_RETAINED {
  pointer_callback = callback;
  pointer_callback_context = context;
  pointer_event_mask = mask;
  pointer_tap_location = tap;
  pointer_tap_options = options;
  return CFMachPortCreate(kCFAllocatorDefault, TestMachPortCallback, NULL, NULL);
}

static void TestEventTapEnable(CFMachPortRef tap, bool enabled) {}

#define CGEventCreate TestEventCreate
#define CGEventPost TestEventPost
#define CGEventTapCreate TestEventTapCreate
#define CGEventTapEnable TestEventTapEnable
#include "../TouchUpCore/TUCCursorUtilities.m"
#undef CGEventCreate
#undef CGEventPost
#undef CGEventTapCreate
#undef CGEventTapEnable

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
    deliverAllPostedEvents();
    defer_event_delivery = NO;
    posted_events = [NSMutableArray new];
    pending_events = [NSMutableArray new];
    movePhysicalPointer(CGPointMake(-240, 125));
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

static BOOL hasSavedPointer(PointerFixture *fixture) {
  return [[fixture.manager valueForKey:@"hasSavedCursorLocation"] boolValue];
}

static void testTap(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  check(hasSavedPointer(fixture) && eventIs(posted_events.firstObject, kCGEventMouseMoved, CGPointMake(800, 400)),
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
  movePhysicalPointer(next_origin);
  [fixture sampleX:10 y:10 onSurface:YES];
  [fixture sampleX:10 y:10 onSurface:NO];
  check(CGPointEqualToPoint(pointer_location, next_origin),
    @"a new touch session captures the pointer's new location");
}

static void testDelayedMouseOutput(void) {
  PointerFixture *fixture = [PointerFixture new];
  fixture.touch_down_action = TUCCursorActionNone;
  [fixture sampleX:0 y:0 onSurface:YES];
  check(!hasSavedPointer(fixture) && posted_events.count == 0, @"an action mapped to None does not capture the pointer");
  CGPoint latest_origin = CGPointMake(-400, 300);
  movePhysicalPointer(latest_origin);
  [fixture sampleX:0 y:0 onSurface:NO];
  check(posted_events.count == 3
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, latest_origin),
    @"tap-only mapping captures immediately before the click and restores after mouse-up");
}

static void testDisabledOutput(void) {
  PointerFixture *fixture = [PointerFixture new];
  fixture.manager.postMouseEvents = NO;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(!hasSavedPointer(fixture) && posted_events.count == 0, @"debug-only touches neither capture nor restore the pointer");

  fixture = [PointerFixture new];
  fixture.manager.restoreCursorAfterTouch = NO;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(!hasSavedPointer(fixture) && posted_events.count == 3 && restoreCount() == 0
    && CGPointEqualToPoint(pointer_location, CGPointMake(800, 400)),
    @"turning restoration off preserves ordinary pointer-following behavior");
  CGPoint physical_location = CGPointMake(-800, 350);
  movePhysicalPointer(physical_location);
  check(CGPointEqualToPoint([[TUCCursorUtilities sharedInstance] currentCursorLocation], physical_location),
    @"with restoration off, both click events acknowledge so later physical mouse movement is observed");

  fixture = [PointerFixture new];
  fixture.touch_down_action = TUCCursorActionNone;
  fixture.tap_action = TUCCursorActionNone;
  fixture.drag_action = TUCCursorActionNone;
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:0 y:0 onSurface:NO];
  check(!hasSavedPointer(fixture) && posted_events.count == 0, @"a touch with no mouse actions never saves or restores a position");
}

static void testMultipleFingers(void) {
  PointerFixture *fixture = [PointerFixture new];
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture updateContact:7 x:0 y:0 onSurface:YES];
  [fixture updateContact:8 x:10 y:0 onSurface:YES];
  [fixture report];
  check(hasSavedPointer(fixture) && restoreCount() == 0, @"adding another finger retains the saved pointer");
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
  movePhysicalPointer(CGPointMake(50, 50));
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

static NSTimer *beginScrollMomentum(PointerFixture *fixture) {
  [fixture sampleX:0 y:0 onSurface:YES];
  [fixture sampleX:4 y:0 onSurface:YES];
  [fixture sampleX:8 y:0 onSurface:YES];
  [fixture sampleX:8 y:0 onSurface:NO];
  return [[TUCCursorUtilities sharedInstance] valueForKey:@"momentumScrollTimer"];
}

static void testScrollMomentum(void) {
  PointerFixture *fixture = [PointerFixture new];
  NSTimer *timer = beginScrollMomentum(fixture);
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  CGPoint scroll_target = eventLocation(posted_events.lastObject);
  check(eventCount(kCGEventScrollWheel) == 3 && timer.isValid && restoreCount() == 0
    && hasSavedPointer(fixture), @"scroll lift-off retains the saved pointer while momentum runs");
  [utils updateMomentumScroll:timer];
  check(eventIs(posted_events.lastObject, kCGEventScrollWheel, scroll_target)
    && CGPointEqualToPoint(pointer_location, scroll_target) && restoreCount() == 0,
    @"momentum moves the pointer at the scroll target before the final restoration");

  NSUInteger count = posted_events.count;
  NSTimer *unrelated_timer = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer *unused) {}];
  [utils updateMomentumScroll:unrelated_timer];
  check(posted_events.count == count, @"a callback from another timer cannot emit momentum");

  NSUInteger ticks = 0;
  while (timer.isValid && ticks++ < 1000) [utils updateMomentumScroll:timer];
  check(!timer.isValid && restoreCount() == 1 && !hasSavedPointer(fixture)
    && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location)
    && CGPointEqualToPoint(pointer_location, original_location),
    @"natural momentum completion restores exactly once after every wheel event");
  count = posted_events.count;
  [utils updateMomentumScroll:timer];
  [fixture report];
  check(posted_events.count == count, @"a completed timer and empty report cannot move the pointer again");
}

static void testNewTouchDuringMomentum(void) {
  for (NSNumber *mapping in @[@(TUCCursorActionNone), @(TUCCursorActionClick)]) {
    PointerFixture *fixture = [PointerFixture new];
    NSTimer *old_timer = beginScrollMomentum(fixture);
    fixture.touch_down_action = mapping.integerValue;
    [fixture sampleX:20 y:10 onSurface:YES];
    check(!old_timer.isValid && restoreCount() == 0 && hasSavedPointer(fixture),
      [NSString stringWithFormat:@"new touch mapped to %@ cancels inertia without restoring over the new contact", mapping]);
    NSUInteger count = posted_events.count;
    [[TUCCursorUtilities sharedInstance] updateMomentumScroll:old_timer];
    check(posted_events.count == count, @"an interrupted timer cannot post into the next touch session");
    [fixture sampleX:20 y:10 onSurface:NO];
    check(restoreCount() == 1 && CGPointEqualToPoint(pointer_location, original_location),
      @"the next touch retains the original pointer saved before the interrupted scroll");
  }

  PointerFixture *fixture = [PointerFixture new];
  NSTimer *old_timer = beginScrollMomentum(fixture);
  fixture.touch_down_action = TUCCursorActionNone;
  fixture.tap_action = TUCCursorActionScroll;
  [fixture sampleX:20 y:10 onSurface:YES];
  [fixture sampleX:20 y:10 onSurface:NO];
  check(!old_timer.isValid && ![[TUCCursorUtilities sharedInstance] valueForKey:@"momentumScrollTimer"]
    && restoreCount() == 1 && CGPointEqualToPoint(pointer_location, original_location),
    @"a tap mapped to Scroll cannot inherit velocity from the interrupted gesture");
}

static void testMomentumCleanup(void) {
  NSArray<NSString *> *operations = @[@"disconnect", @"stop", @"disable mouse output"];
  for (NSUInteger operation = 0; operation < operations.count; operation++) {
    PointerFixture *fixture = [PointerFixture new];
    NSTimer *timer = beginScrollMomentum(fixture);
    switch (operation) {
      case 0: TouchInputManagerDidDisconnectTouchscreen((__bridge void *)fixture.manager, 1); break;
      case 1: [fixture.manager stop]; break;
      default: fixture.manager.postMouseEvents = NO; break;
    }
    check(!timer.isValid && restoreCount() == 1 && !hasSavedPointer(fixture)
      && eventIs(posted_events.lastObject, kCGEventMouseMoved, original_location),
      [NSString stringWithFormat:@"%@ cancels outstanding momentum and restores immediately", operations[operation]]);
    NSUInteger count = posted_events.count;
    [[TUCCursorUtilities sharedInstance] updateMomentumScroll:timer];
    [fixture report];
    check(posted_events.count == count, @"cleanup cannot leave a momentum callback that moves the pointer later");
  }
}

static void testMomentumPixelTail(void) {
  __unused PointerFixture *fixture = [PointerFixture new];
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  CGPoint target = CGPointMake(800, 400);
  [utils scroll:CGPointMake(1, -1) phase:NSTouchPhaseMoved atLocation:target];
  [utils scroll:CGPointZero phase:NSTouchPhaseEnded atLocation:target];
  NSTimer *timer = [utils valueForKey:@"momentumScrollTimer"];
  __block NSUInteger completions = 0;
  [utils finishMomentumScrollWithCompletion:^{ completions++; }];
  NSUInteger count = posted_events.count;
  [utils updateMomentumScroll:timer];
  check(!timer.isValid && completions == 1 && posted_events.count == count,
    @"momentum finishes when decay produces zero integer pixels, without a silent fractional tail");
  [utils finishMomentumScrollWithCompletion:^{ completions++; }];
  check(completions == 2, @"finishing without active momentum completes immediately");
}

static void testQueuedTapSessions(void) {
  PointerFixture *fixture = [PointerFixture new];
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  [fixture sampleX:0 y:0 onSurface:YES];
  NSUInteger reads = cursor_reads;
  defer_event_delivery = YES;
  [fixture sampleX:0 y:0 onSurface:NO];
  check(!CGPointEqualToPoint(pointer_location, original_location)
    && CGPointEqualToPoint([utils currentCursorLocation], original_location),
    @"a queued restore supplies its logical position before WindowServer moves the pointer");

  [fixture sampleX:20 y:10 onSurface:YES];
  CGPoint second_target = CGPointMake(900, 450);
  deliverNextPostedEvent();
  deliverNextPostedEvent();
  deliverNextPostedEvent();
  check(CGPointEqualToPoint(pointer_location, original_location)
    && CGPointEqualToPoint([utils currentCursorLocation], second_target),
    @"an old restore acknowledgement cannot discard a newer queued touch move");
  [fixture sampleX:20 y:10 onSurface:NO];
  deliverAllPostedEvents();
  check(restoreCount() == 2 && CGPointEqualToPoint(pointer_location, original_location),
    @"back-to-back taps restore the original pointer even when the first restore was still queued");
  check(cursor_reads == reads, @"queued touch processing never rereads a stale system pointer snapshot");

  BOOL ordered_tags = YES;
  int64_t previous_id = 0;
  for (NSDictionary *event in posted_events) {
    int64_t event_id = [event[@"event_id"] longLongValue];
    if (event_id <= previous_id) ordered_tags = NO;
    previous_id = event_id;
  }
  check(ordered_tags, @"every posted touch event carries a distinct ordered acknowledgement marker");
}

static void testAcknowledgementBeforePointerCommit(void) {
  PointerFixture *fixture = [PointerFixture new];
  TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
  [fixture sampleX:0 y:0 onSurface:YES];
  defer_event_delivery = YES;
  [fixture sampleX:0 y:0 onSurface:NO];
  deliverNextPostedEvent();
  deliverNextPostedEvent();
  CGEventRef restore = takeNextPostedEvent();
  NSUInteger reads = cursor_reads;
  observePointerEvent(restore);
  check(!CGPointEqualToPoint(pointer_location, original_location)
    && CGPointEqualToPoint([utils currentCursorLocation], original_location)
    && cursor_reads == reads,
    @"restore acknowledgement uses the observed event location before the system cursor snapshot commits");
  applyPointerEvent(restore);
  CFRelease(restore);

  CGPoint physical_location = CGPointMake(-500, 220);
  movePhysicalPointer(physical_location);
  check(CGPointEqualToPoint([utils currentCursorLocation], physical_location),
    @"physical mouse movement replaces the restored logical position after acknowledgement");
  [fixture sampleX:30 y:20 onSurface:YES];
  [fixture sampleX:30 y:20 onSurface:NO];
  deliverAllPostedEvents();
  check(CGPointEqualToPoint(pointer_location, physical_location),
    @"a touch after physical mouse movement saves and restores the new position");
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
    testNewTouchDuringMomentum();
    testMomentumCleanup();
    testMomentumPixelTail();
    testQueuedTapSessions();
    testAcknowledgementBeforePointerCommit();
    check(pointer_tap_location == kCGAnnotatedSessionEventTap
      && pointer_tap_options == kCGEventTapOptionListenOnly
      && (pointer_event_mask & CGEventMaskBit(kCGEventScrollWheel))
      && !(pointer_event_mask & (CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp))),
      @"cursor tracking passively observes pointer events without monitoring keyboard input");
    printf("\n%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
