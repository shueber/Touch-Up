//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"

NS_ASSUME_NONNULL_BEGIN

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property BOOL isLeftMouseDown;
@property CGPoint lastDragLocation;

@property CGPoint momentumScrollTranslation;
@property CGPoint momentumScrollLocation;
@property (strong, nullable) NSTimer *momentumScrollTimer;
@property (copy, nullable) void (^momentumScrollCompletion)(void);

@property (nullable) CFMachPortRef cursorEventTap;
@property (nullable) CFRunLoopSourceRef cursorEventSource;
@property CGPoint observedCursorLocation;
@property CGPoint queuedCursorLocation;
@property int64_t queuedCursorEventID;
@property BOOL hasQueuedCursorEvent;
@property BOOL didLogCursorTrackingFailure;

- (void)observeCursorEvent:(nullable CGEventRef)event type:(CGEventType)type;

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@end

static CGEventRef _Nullable ObserveCursorEvent(CGEventTapProxy _Nullable proxy, CGEventType type,
                                              CGEventRef _Nullable event, void *context) {
  [(__bridge TUCCursorUtilities *)context observeCursorEvent:event type:type];
  return event;
}

@implementation TUCCursorUtilities

+ (TUCCursorUtilities *)sharedInstance {
    static TUCCursorUtilities *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!sharedInstance) {
            sharedInstance = [[TUCCursorUtilities alloc] init];
            sharedInstance.isLeftMouseDown = NO;
            sharedInstance.cursorClickCount = 0;
            sharedInstance.timeOfLastClick = [NSDate dateWithTimeIntervalSince1970:0];
            sharedInstance.locationOfLastClick = CGPointZero;
        }
    });
    return sharedInstance;
}





- (CGPoint)systemCursorLocation {
  CGEventRef event = CGEventCreate(NULL);
  CGPoint location = CGEventGetLocation(event);
  CFRelease(event);
  return location;
}

- (void)startObservingCursor {
  if (self.cursorEventTap) return;
  CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
    | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
    | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
    | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)
    | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged)
    | CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventScrollWheel)
    | CGEventMaskBit(29); // Gesture events also carry the cursor location.
  self.cursorEventTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGTailAppendEventTap,
    kCGEventTapOptionListenOnly, mask, ObserveCursorEvent, (__bridge void *)self);
  if (!self.cursorEventTap) {
    if (!self.didLogCursorTrackingFailure) {
      NSLog(@"Touch Up cannot observe pointer events; rapid-touch pointer restoration may be inaccurate. Check Input Monitoring and Accessibility permissions.");
      self.didLogCursorTrackingFailure = YES;
    }
    return;
  }
  self.cursorEventSource = CFMachPortCreateRunLoopSource(NULL, self.cursorEventTap, 0);
  if (!self.cursorEventSource) {
    CFMachPortInvalidate(self.cursorEventTap);
    CFRelease(self.cursorEventTap);
    self.cursorEventTap = NULL;
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), self.cursorEventSource, kCFRunLoopCommonModes);
  self.observedCursorLocation = [self systemCursorLocation];
  self.queuedCursorEventID = (int64_t)arc4random_uniform(INT32_MAX) << 32;
}

- (void)observeCursorEvent:(nullable CGEventRef)event type:(CGEventType)type {
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    self.hasQueuedCursorEvent = NO;
    self.observedCursorLocation = [self systemCursorLocation];
    CGEventTapEnable(self.cursorEventTap, true);
    return;
  }
  self.observedCursorLocation = CGEventGetLocation(event);
  if (self.hasQueuedCursorEvent &&
      CGEventGetIntegerValueField(event, kCGEventSourceUserData) == self.queuedCursorEventID) {
    self.hasQueuedCursorEvent = NO;
  }
}

- (CGPoint)currentCursorLocation {
  [self startObservingCursor];
  if (!self.cursorEventTap) return [self systemCursorLocation];
  // CGEventPost is asynchronous. A second touch must see the first touch's queued
  // restore, even before WindowServer has moved the visible pointer there.
  return self.hasQueuedCursorEvent ? self.queuedCursorLocation : self.observedCursorLocation;
}

- (void)postCursorEvent:(CGEventRef)event {
  [self startObservingCursor];
  // Core Graphics retains the first source-data value on a reused event. Tag a
  // fresh copy so a click's down/up posts each receive their own acknowledgment.
  CGEventRef postedEvent = CGEventCreateCopy(event);
  if (self.cursorEventTap) {
    self.queuedCursorEventID++;
    self.queuedCursorLocation = CGEventGetLocation(postedEvent);
    self.hasQueuedCursorEvent = YES;
    CGEventSetIntegerValueField(postedEvent, kCGEventSourceUserData, self.queuedCursorEventID);
  }
  CGEventPost(kCGHIDEventTap, postedEvent);
  CFRelease(postedEvent);
}

- (void)dealloc {
  if (_cursorEventSource) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _cursorEventSource, kCFRunLoopCommonModes);
    CFRelease(_cursorEventSource);
  }
  if (_cursorEventTap) {
    CFMachPortInvalidate(_cursorEventTap);
    CFRelease(_cursorEventTap);
  }
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    [self restoreCursorTo:aLocation];
}

- (void)restoreCursorTo:(CGPoint)aLocation {
    // Keep restoration in the same posted event stream as the final click/drop.
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    [self postCursorEvent:event];
    CFRelease(event);
}



- (void)bringWindowToFrontAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventTimestamp time = CGEventGetTimestamp(event);
    CGEventSetTimestamp(event, time-1);
    
    [self postCursorEvent:event];
    CGEventSetType(event, kCGEventLeftMouseDragged);
    [self postCursorEvent:event];
    CGEventSetLocation(event, aLocation);
    CGEventSetType(event, kCGEventLeftMouseUp);
    [self postCursorEvent:event];
    
    CFRelease(event);
    //    self.isLeftMouseDown = YES;
}

/**
 integrated double click support: needs checks time between clicks and spatial distance
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
    [self postCursorEvent:event];
    CGEventSetType(event, kCGEventLeftMouseUp);
    [self postCursorEvent:event];
    CFRelease(event);
    
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;
    
    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];
    
    if (durationSinceLastClick > [NSEvent doubleClickInterval] || self.cursorClickCount == 4) {
        self.cursorClickCount = 1;
    }
    
    else if ((aLocation.x - self.locationOfLastClick.x) > self.doubleClickTolerance
             && (aLocation.y - self.locationOfLastClick.y) > self.doubleClickTolerance) {
        // touch is too far away
        self.cursorClickCount = 1;
    }
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    [self postCursorEvent:event];
    CGEventSetType(event, kCGEventRightMouseUp);
    [self postCursorEvent:event];
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    self.lastDragLocation = aLocation;

    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postCursorEvent:event];
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postCursorEvent:event];
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, self.lastDragLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postCursorEvent:event];
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
  [self scroll:translation phase:phase atLocation:[self currentCursorLocation]];
}

- (void)postScroll:(CGPoint)translation atLocation:(CGPoint)location {
  CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2,
    translation.y, translation.x, 0);
  CGEventSetLocation(event, location);
  [self postCursorEvent:event];
  CFRelease(event);
}

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase atLocation:(CGPoint)location {
  CGPoint lastTranslation = self.momentumScrollTranslation;
  [self cancelMomentumScroll];
  [self stopDraggingCursor];
  [self postScroll:translation atLocation:location];
  self.momentumScrollLocation = location;

  if (phase == NSTouchPhaseEnded) {
    self.momentumScrollTranslation = lastTranslation;
    if (fabs(lastTranslation.x) >= 1 || fabs(lastTranslation.y) >= 1) {
      self.momentumScrollTimer = [NSTimer timerWithTimeInterval:0.01 target:self
        selector:@selector(updateMomentumScroll:) userInfo:nil repeats:YES];
      [[NSRunLoop mainRunLoop] addTimer:self.momentumScrollTimer forMode:NSRunLoopCommonModes];
    }
  } else {
    self.momentumScrollTranslation = translation;
  }
}

- (void)updateMomentumScroll:(nullable NSTimer *)timer {
  if (timer != self.momentumScrollTimer || !timer.isValid) return;
  self.momentumScrollTranslation = CGPointMake(self.momentumScrollTranslation.x * 0.985,
    self.momentumScrollTranslation.y * 0.985);

  // The emitted pixel deltas are integers. Fractional tails produce no scrolling
  // and would otherwise delay pointer restoration by another 1.5 seconds.
  if (fabs(self.momentumScrollTranslation.x) < 1 && fabs(self.momentumScrollTranslation.y) < 1) {
    void (^completion)(void) = self.momentumScrollCompletion;
    [self cancelMomentumScroll];
    if (completion) completion();
    return;
  }
  [self postScroll:self.momentumScrollTranslation atLocation:self.momentumScrollLocation];
}

- (void)finishMomentumScrollWithCompletion:(void (^)(void))completion {
  if (self.momentumScrollTimer.isValid) {
    self.momentumScrollCompletion = completion;
  } else {
    completion();
  }
}

- (void)cancelMomentumScroll {
  [self.momentumScrollTimer invalidate];
  self.momentumScrollTimer = nil;
  self.momentumScrollCompletion = nil;
  self.momentumScrollTranslation = CGPointZero;
}


- (void)magnify:(CGFloat)magnification phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];
    
    if (phase == NSTouchPhaseMoved && magnification == 0) {
        // no reason to post that
        return;
    }
    
    // start with a valid mouse event, as it has a valid timestamp
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, [self currentCursorLocation], kCGMouseButtonLeft);
    
    CGEventSetType(event, 29); // type gesture
    CGEventSetFlags(event, 0);
    
    CGEventSetDoubleValueField(event, 113, magnification);
    CGEventSetDoubleValueField(event, 114, magnification);
    CGEventSetDoubleValueField(event, 116, magnification);
    CGEventSetDoubleValueField(event, 118, magnification);
    
    // magic
//    CGEventSetIntegerValueField(event, 55, 29); //if more touches on trackapd 30? about concurrent gestures???
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, 110, 8);
    
    
    CGGesturePhase gesturePhase = kCGGesturePhaseEnded;
    if (phase == NSTouchPhaseBegan) {
        gesturePhase = kCGGesturePhaseBegan;
    } else if (phase == NSTouchPhaseMoved || phase == NSTouchPhaseStationary) {
        gesturePhase = kCGGesturePhaseChanged;
    }
    
    CGEventSetIntegerValueField(event, 132, phase);
    
    [self postCursorEvent:event];
    CFRelease(event);
}


- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2 {
    [self stopDraggingCursor];
    
    NSTouchPhase phase = NSTouchPhaseMoved;
    
    CGFloat dx = r1.x - r2.x;
    CGFloat dy = r1.y - r2.y;
    
    CGFloat distance = sqrt( pow(dx, 2) + pow(dy, 2) );
    CGFloat delta = distance - self.lastPinchDistance;
    
    self.lastPinchDistance = distance;
    
    if (!self.isMagnifying) {
        CGPoint middle = CGPointMake(0.5f * (p1.x + p2.x), 0.5f * (p1.y + p2.y));
        [self moveCursorTo:middle];
        phase = NSTouchPhaseBegan;
        delta = 0;
        self.isMagnifying = YES;
    }
    
    [self magnify:delta * 4 phase:phase];
}


- (void)stopMagnifying {
    if (self.isMagnifying) {
        self.isMagnifying = NO;
        [self magnify:0 phase:NSTouchPhaseEnded];
    }
}

@end

NS_ASSUME_NONNULL_END
