//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property (readwrite) BOOL isLeftMouseDown;

@property CGPoint momentumScrollTranslation;
@property (strong) NSTimer *momentumScrollTimer;

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@end

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





- (CGPoint)currentCursorLocation {
    CGEventRef dummy = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(dummy);
    CFRelease(dummy);
    return location;
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)bringWindowToFrontAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventTimestamp time = CGEventGetTimestamp(event);
    CGEventSetTimestamp(event, time-1);
    
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseDragged);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetLocation(event, aLocation);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    
    CFRelease(event);
    //    self.isLeftMouseDown = YES;
}

/**
 Posts a complete press and release. Integrated double click support: checks time between
 clicks and spatial distance.

 Both halves are emitted here, at the moment the finger lifts, so a plain tap has no
 press-and-hold phase for an app to observe. That is not an oversight, and moving the press
 to touch-down would break one-finger scrolling: while the finger is still on the glass the
 gesture is genuinely undecided — tap, scroll, pinch and secondary click all start
 identically — and a press that has already been delivered cannot be taken back, so an app
 would begin selecting text the moment the user meant to scroll. The press can only be
 emitted early once the gesture is no longer ambiguous, which is what the hold does; see
 `TUCCursorGestureLongPress` and `-dragCursorTo:phase:`.
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];

    // Two purpose-built events rather than one object re-typed and posted twice: that shared
    // a single creation timestamp between the press and the release, so the pair carried a
    // press duration of exactly zero.
    CGEventRef mouseDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(mouseDown, kCGMouseEventClickState, self.cursorClickCount);
    CGEventPost(kCGHIDEventTap, mouseDown);
    CFRelease(mouseDown);

    CGEventRef mouseUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(mouseUp, kCGMouseEventClickState, self.cursorClickCount);
    CGEventPost(kCGHIDEventTap, mouseUp);
    CFRelease(mouseUp);
}


/**
 Advances the click sequence that gets stamped onto the next mouse event as its click state,
 so that quick repeat presses in the same spot read as a double or triple click.

 A sequence continues only while both conditions hold: the presses follow each other within
 the system's double-click interval, and the new one lands inside `doubleClickTolerance` of
 the previous one. Anything else starts a fresh sequence at 1.

 The count is not capped. A real mouse keeps counting past a triple click — a quadruple click
 selects a paragraph in some text views — and it used to wrap back to 1 on the fourth press
 here, which made the *fifth* press of a rapid series look like the second press of a new
 double click. Rapid repeat tapping therefore produced double clicks the user never asked
 for.
 */
- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;

    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];

    if (durationSinceLastClick > [NSEvent doubleClickInterval]) {
        self.cursorClickCount = 1;
    }

    // Distance from the previous click, as a radius. This used to compare the two signed
    // axis deltas against the tolerance and require *both* to exceed it, which only ever
    // held for a tap moving down and to the right — so in every other direction two quick
    // taps anywhere on the glass were promoted to a double click. That is easy to trigger on
    // a large touchscreen, where consecutive taps are naturally far apart.
    else if (hypot(aLocation.x - self.locationOfLastClick.x,
                   aLocation.y - self.locationOfLastClick.y) > self.doubleClickTolerance) {
        // touch is too far away
        self.cursorClickCount = 1;
    }

    // Every press that advances the sequence also becomes the reference for the next one.
    // This used to be done by `performClickAt:` alone, so the press that starts a drag
    // consumed a count without moving the reference forward: the window for the following
    // tap was still measured from the click *before* the drag, letting that tap inherit a
    // count it had not earned — tap, drag, tap at one spot arrived as a triple click.
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventRightMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    
    
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, [self currentCursorLocation], kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, translation.y, translation.x, 0);
    
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    
    if (phase == NSTouchPhaseEnded) {
        // TODO: consider sampling rate of digitizer and screen refresh rate
        [self cancelMomentumScroll];
        
        self.momentumScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(updateMomentumScroll) userInfo:nil repeats:YES];
    } else {
        self.momentumScrollTranslation = translation;
    }
}



- (void)updateMomentumScroll {
    self.momentumScrollTranslation = CGPointMake(self.momentumScrollTranslation.x * 0.985,
                                                 self.momentumScrollTranslation.y * 0.985);
    
    if (fabs(self.momentumScrollTranslation.x) < 0.1 && fabs(self.momentumScrollTranslation.y) < 0.1) {
        [self cancelMomentumScroll];
    }
    
    [self scroll:self.momentumScrollTranslation phase:NSTouchPhaseMoved];
}



- (void)cancelMomentumScroll {
    if (self.momentumScrollTimer != nil) {
        [self.momentumScrollTimer invalidate];
        self.momentumScrollTimer = nil;
    }
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
    
    CGEventPost(kCGHIDEventTap, event);
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
