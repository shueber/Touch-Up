//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"

@interface TUCTouchInputManager ()

@property NSMutableDictionary<NSNumber *, NSNumber *> *frameIDsByLocationID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchStationarySinceDate;

@property CGFloat pinchDistance;

@property TUCCursorGesture identifiedMultitouchGesture;

// Multi-finger swipe tracking. `swipeStartPoints` maps each tracked touch to the relative
// screen point it had when tracking began; the gesture fires once the average travel of all
// tracked fingers exceeds `swipeThreshold` mm in one direction.
@property BOOL swipeTrackingActive;
@property BOOL swipeShortcutFired;
@property (strong) NSMutableDictionary<NSUUID *, NSValue *> *swipeStartPoints;
@property (strong) NSMutableSet<NSUUID *> *swipeTrackedUUIDs;

// Tap / long-press detection state for the same multi-finger sessions.
// A session becomes a tap if the fingers barely moved and lifted quickly,
// a long-press if they stayed still past `longPressDuration`, and a swipe
// if they travelled past `swipeThreshold`. The first match wins: once a
// long-press began, swipe identification is suspended; a recognized swipe
// cancels tap/long-press evaluation.
@property (strong) NSDate *multiFingerSessionStartDate;
@property NSInteger multiFingerSessionMaxCount;
@property BOOL keyboardHoldActive;
@property TUCCursorGesture activeKeyboardHoldGesture;

@end


// Average travel below this (mm) still counts as "stationary" for tap / long-press.
static const CGFloat kTapTravelThresholdMM = 3.0;
// A multi-finger session that lifts faster than this (s) counts as a tap.
static const NSTimeInterval kTapMaxDuration = 0.35;


@implementation TUCTouchInputManager

#pragma mark   Start & Stop

- (void)start {
    
    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
    OpenHIDManager((__bridge void *)(weakSelf));
//    }];
    
}

- (void)stop {
    CloseHIDManager();
}

- (void)setTouchscreensSeized:(BOOL)seized {
    SetTouchDevicesSeized(seized);
}


- (void)didConnectTouchscreenWithLocationID:(uint32_t)locationID {
    self.frameIDsByLocationID[@(locationID)] = @0;
    [self.delegate touchscreenDidConnectWithLocationID:locationID];
}

- (void)didDisconnectTouchscreenWithLocationID:(uint32_t)locationID {
    [self.frameIDsByLocationID removeObjectForKey:@(locationID)];
    [self.delegate touchscreenDidDisconnectWithLocationID:locationID];
}



#pragma mark - Reacting to HID Events

- (NSInteger)currentFrameIDForLocationID:(uint32_t)locationID {
    return self.frameIDsByLocationID[@(locationID)].integerValue;
}

- (void)didProcessReportForLocationID:(uint32_t)locationID {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    NSInteger currentFrameID = [self currentFrameIDForLocationID:locationID];

    for (TUCTouch *touch in self.touchSet) {
        if (touch.locationID != locationID) continue;

        if (touch.lastUpdated + self.errorResistance < currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }

    self.frameIDsByLocationID[@(locationID)] = @(currentFrameID + 1);

    [self processTouchesForCursorInput];

}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchStationarySinceDate = nil;
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not.
        // Convert each axis to mm first (x scales with the panel width, y with its height),
        // then take the distance — otherwise a non-square screen distorts the threshold per axis.
        CGSize physicalSize = [self touchscreenForLocationID:locationID].nativePhysicalSize;
        CGFloat dxMM = (touch.location.x - touch.previousLocation.x) * physicalSize.width;
        CGFloat dyMM = (touch.location.y - touch.previousLocation.y) * physicalSize.height;
        CGFloat movedDistanceMM = sqrt(dxMM * dxMM + dyMM * dyMM);
        BOOL isStationary = movedDistanceMM < self.stationaryThreshold;
        
        if (touch.uuid == self.cursorTouch.uuid) {
            if (!isStationary) {
                self.cursorTouchQualifiedForTap = NO;
                self.cursorTouchStationarySinceDate = nil;
                
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                self.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;

    NSSet<TUCTouch *> *activeTouches = [self activeTouches];

    // Three or more fingers (or an already latched swipe) leave the normal
    // cursor/scroll/click pipeline: all mouse events are suppressed until the
    // fingers that started the swipe have lifted again.
    if ([self shouldHandleMultiFingerSwipes:activeTouches]) {
        [self handleMultiFingerSwipesWithTouches:activeTouches];
        return;
    }

    NSArray<TUCTouch *> *touches = [activeTouches allObjects];
    NSTouchPhase phase = cursorTouch.phase;
    
    
    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }
        
        [self checkForSecondaryClick];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.cursorTouchDidHold) {
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
            } else if (!self.cursorTouchQualifiedForTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        }
        
        [self stopCurrentGesture];
        
        if (self.cursorTouchQualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        } else {
            if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
                [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            }
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        return;
    }
    
    if ([self checkForSecondaryClick]) {
        return;
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        // check if we need to initiate two finger drag, pinch, ...
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            
            TUCTouch *otherTouch = touches[1];
            if (otherTouch.uuid == cursorTouch.uuid) {
                otherTouch = touches[0];
            }
            
            self.gestureAdditionalTouch = otherTouch;
            
            if (self.gestureAdditionalTouch.isActive) {
                CGPoint trajectoryA = [cursorTouch trajectorySign];
                CGPoint trajectoryB = [otherTouch trajectorySign];
                
                
                if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                    && !CGPointEqualToPoint(trajectoryB, CGPointZero)) {
                    
                    if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                        self.identifiedMultitouchGesture = TUCCursorGesturePinch;
                    }
                    //                    else {
                    //                        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
                    //                    }
                }
                
            } else {
                // secondary click
                [self removeTouch:self.gestureAdditionalTouch now:YES];
                self.gestureAdditionalTouch = nil;
                [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            }
        }
        
        // other finger lifted, gesture ended
        if (!self.gestureAdditionalTouch.isActive) {
            [self stopCurrentGesture];
        }
        
        
        if(self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            return;
        }
        
    }
    
    
    if (self.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


- (BOOL)checkForSecondaryClick {
    //    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
    //        return NO;
    //    }
    
    NSSet<TUCTouch *> *touchesInProximity = [self touchesInProximityTo:self.cursorTouch.location maxDistance:60 locationID:self.cursorTouch.locationID];
    if (touchesInProximity.count >= 2 && self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
        
        // TUCCursorGestureTwoFingerTap
        NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseEnded];
        NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseCancelled];
        
        NSPredicate *p3 = [NSPredicate predicateWithFormat:@"contactID != %d", self.cursorTouch.contactID];
        
        NSPredicate *p4 = [NSCompoundPredicate orPredicateWithSubpredicates:@[p1, p2]];
        NSPredicate *p5 = [NSCompoundPredicate andPredicateWithSubpredicates:@[p3, p4]];
        
        NSSet<TUCTouch *> *endedTouches = [touchesInProximity filteredSetUsingPredicate:p5];
        
        if (endedTouches.count == 1) {
            for (TUCTouch* touchToRemove in endedTouches) {
                [self removeTouch:touchToRemove now:YES];
            }
            
            [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            return YES;
        }
    }
    return NO;
}


#pragma mark - Multi-Finger Gestures

/**
 Decides whether the current touch configuration belongs to the multi-finger gesture pipeline.
 Once a session is latched it stays in the pipeline until every tracked finger lifted.
 */
- (BOOL)shouldHandleMultiFingerSwipes:(NSSet<TUCTouch *> *)activeTouches {
    if (self.swipeTrackingActive) {
        return YES;
    }
    if (!self.threeFingerSwipesEnabled && !self.fourFingerSwipesEnabled) {
        return NO;
    }
    if (activeTouches.count >= 4) {
        return self.fourFingerSwipesEnabled;
    }
    if (activeTouches.count == 3) {
        return self.threeFingerSwipesEnabled;
    }
    return NO;
}


- (void)handleMultiFingerSwipesWithTouches:(NSSet<TUCTouch *> *)activeTouches {

    if (activeTouches.count >= 3) {
        if (!self.swipeTrackingActive) {
            self.swipeTrackingActive = YES;
            self.swipeShortcutFired = NO;
            self.multiFingerSessionStartDate = [NSDate date];
            self.multiFingerSessionMaxCount = activeTouches.count;
            [self.swipeStartPoints removeAllObjects];
            [self.swipeTrackedUUIDs removeAllObjects];
        }

        if ((NSInteger)activeTouches.count > self.multiFingerSessionMaxCount) {
            self.multiFingerSessionMaxCount = activeTouches.count;
        }

        // Record the start point of every touch that is not part of the session yet.
        for (TUCTouch *touch in activeTouches) {
            if (touch.locationID != self.cursorTouch.locationID) continue;
            if (self.swipeStartPoints[touch.uuid] == nil) {
                self.swipeStartPoints[touch.uuid] = [NSValue valueWithPoint:touch.location];
                [self.swipeTrackedUUIDs addObject:touch.uuid];
            }
        }
    }

    // Gesture identification. Swipe wins once the travel threshold is crossed; a
    // recognized long-press suspends swipe identification so hold and swipe can
    // never both fire for one session.
    if (self.swipeTrackingActive && self.identifiedMultitouchGesture == _TUCCursorGestureNone && !self.keyboardHoldActive) {
        [self identifyMultiFingerSwipeWithTouches:activeTouches];

        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
            [self checkForMultiFingerLongPressWithTouches:activeTouches];
        }
    }

    // The mapped keyboard shortcut fires exactly once, as soon as the gesture is recognized.
    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone && !self.swipeShortcutFired) {
        self.swipeShortcutFired = YES;
        [self performMouseEventForGesture:self.identifiedMultitouchGesture];
    }

    // The session ends when every finger that started it has lifted. Fingers that only
    // came down afterwards don't keep it alive.
    BOOL trackedTouchStillActive = NO;
    for (TUCTouch *touch in activeTouches) {
        if ([self.swipeTrackedUUIDs containsObject:touch.uuid]) {
            trackedTouchStillActive = YES;
            break;
        }
    }
    if (activeTouches.count >= 3 || trackedTouchStillActive) {
        return;
    }

    // Session over: end a possibly active keyboard hold, or evaluate the session as a tap.
    if (self.keyboardHoldActive) {
        [self.delegate endKeyboardHoldForGesture:self.activeKeyboardHoldGesture];
    } else if (self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
        [self checkForMultiFingerTap];
    }

    // Remove the ended swipe touches immediately so their pending release cannot
    // post a stray click, drag or scroll after the gesture.
    for (NSUUID *uuid in self.swipeTrackedUUIDs) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
        TUCTouch *touch = [[self.touchSet filteredSetUsingPredicate:predicate] anyObject];
        if (touch) {
            [self removeTouch:touch now:YES];
        }
    }

    // If an untracked finger (one that landed mid-swipe) is still down, hand it the cursor.
    if (!self.cursorTouch.isActive) {
        if (activeTouches.count > 0) {
            self.cursorTouch = [activeTouches anyObject];
        }
        self.cursorTouchQualifiedForTap = NO;
    }

    [self resetSwipeTracking];
}


/**
 Averages the travel (mm) of all tracked touches that are present in `touches`.
 Returns NO if fewer than three tracked touches could be evaluated.
 */
- (BOOL)computeAverageTravelDX:(CGFloat *)outDX dy:(CGFloat *)outDY ofTouches:(NSSet<TUCTouch *> *)touches {
    CGFloat sumDX = 0;
    CGFloat sumDY = 0;
    NSInteger trackedCount = 0;

    for (TUCTouch *touch in touches) {
        NSValue *startValue = self.swipeStartPoints[touch.uuid];
        if (startValue == nil) continue;

        TUCScreen *screen = [self touchscreenForLocationID:touch.locationID];
        CGPoint start = startValue.pointValue;

        // relative point × physical size = mm travelled on the glass
        sumDX += (touch.location.x - start.x) * screen.nativePhysicalSize.width;
        sumDY += (touch.location.y - start.y) * screen.nativePhysicalSize.height;
        trackedCount++;
    }

    if (trackedCount < 3) return NO;

    *outDX = sumDX / trackedCount;
    *outDY = sumDY / trackedCount;
    return YES;
}


/**
 Computes the average travel of all tracked fingers (in mm, per axis using each touch's own
 screen dimensions) and classifies the dominant direction once it exceeds `swipeThreshold`.
 */
- (void)identifyMultiFingerSwipeWithTouches:(NSSet<TUCTouch *> *)activeTouches {
    BOOL useFourFingerGestures = activeTouches.count >= 4 && self.fourFingerSwipesEnabled;
    if (!useFourFingerGestures && !self.threeFingerSwipesEnabled) {
        return;
    }

    CGFloat avgDX = 0;
    CGFloat avgDY = 0;
    if (![self computeAverageTravelDX:&avgDX dy:&avgDY ofTouches:activeTouches]) return;

    BOOL horizontal = fabs(avgDX) > fabs(avgDY);
    TUCCursorGesture gesture;

    if (horizontal) {
        if (fabs(avgDX) < self.swipeThreshold) return;
        if (avgDX > 0) {
            gesture = useFourFingerGestures ? TUCCursorGestureFourFingerSwipeRight : TUCCursorGestureThreeFingerSwipeRight;
        } else {
            gesture = useFourFingerGestures ? TUCCursorGestureFourFingerSwipeLeft : TUCCursorGestureThreeFingerSwipeLeft;
        }
    } else {
        if (fabs(avgDY) < self.swipeThreshold) return;
        // relative y grows downward, so positive dy is a downward swipe
        if (avgDY > 0) {
            gesture = useFourFingerGestures ? TUCCursorGestureFourFingerSwipeDown : TUCCursorGestureThreeFingerSwipeDown;
        } else {
            gesture = useFourFingerGestures ? TUCCursorGestureFourFingerSwipeUp : TUCCursorGestureThreeFingerSwipeUp;
        }
    }

    self.identifiedMultitouchGesture = gesture;
}


/**
 Recognizes a long-press once the fingers have stayed nearly still for `longPressDuration`.
 Called only while no swipe has been identified and no hold is active, so a recognized
 hold permanently wins over a swipe for the rest of the session.
 */
- (void)checkForMultiFingerLongPressWithTouches:(NSSet<TUCTouch *> *)activeTouches {
    if (self.keyboardHoldActive) return;
    if (self.multiFingerSessionStartDate == nil) return;
    if (-[self.multiFingerSessionStartDate timeIntervalSinceNow] < self.longPressDuration) return;

    CGFloat avgDX = 0;
    CGFloat avgDY = 0;
    if (![self computeAverageTravelDX:&avgDX dy:&avgDY ofTouches:activeTouches]) return;
    if (sqrt(avgDX * avgDX + avgDY * avgDY) >= kTapTravelThresholdMM) return;

    BOOL useFourFingerGestures = activeTouches.count >= 4 && self.fourFingerSwipesEnabled;
    if (!useFourFingerGestures && !self.threeFingerSwipesEnabled) return;

    TUCCursorGesture gesture = useFourFingerGestures
        ? TUCCursorGestureFourFingerLongPress
        : TUCCursorGestureThreeFingerLongPress;

    self.keyboardHoldActive = YES;
    self.activeKeyboardHoldGesture = gesture;
    [self.delegate beginKeyboardHoldForGesture:gesture];
}


/**
 Evaluates the finished session as a possible tap: the fingers must have barely moved
 and lifted quickly. Only reached when neither a swipe nor a long-press was recognized.
 */
- (void)checkForMultiFingerTap {
    if (self.multiFingerSessionStartDate == nil) return;

    NSTimeInterval duration = -[self.multiFingerSessionStartDate timeIntervalSinceNow];
    if (duration > kTapMaxDuration) return;

    // The active set is already empty at session end, so evaluate the travel
    // against the touches' last known positions still in the touch set.
    NSMutableSet<TUCTouch *> *lastPositions = [NSMutableSet new];
    for (NSUUID *uuid in self.swipeTrackedUUIDs) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
        TUCTouch *touch = [[self.touchSet filteredSetUsingPredicate:predicate] anyObject];
        if (touch) [lastPositions addObject:touch];
    }

    CGFloat avgDX = 0;
    CGFloat avgDY = 0;
    if (![self computeAverageTravelDX:&avgDX dy:&avgDY ofTouches:lastPositions]) return;
    if (sqrt(avgDX * avgDX + avgDY * avgDY) >= kTapTravelThresholdMM) return;

    BOOL useFourFingerGestures = self.multiFingerSessionMaxCount >= 4 && self.fourFingerSwipesEnabled;
    if (!useFourFingerGestures && !self.threeFingerSwipesEnabled) return;

    TUCCursorGesture gesture = useFourFingerGestures
        ? TUCCursorGestureFourFingerTap
        : TUCCursorGestureThreeFingerTap;

    [self performMouseEventForGesture:gesture];
}


- (void)resetSwipeTracking {
    self.swipeTrackingActive = NO;
    self.swipeShortcutFired = NO;
    self.multiFingerSessionStartDate = nil;
    self.multiFingerSessionMaxCount = 0;
    self.keyboardHoldActive = NO;
    self.activeKeyboardHoldGesture = _TUCCursorGestureNone;
    [self.swipeStartPoints removeAllObjects];
    [self.swipeTrackedUUIDs removeAllObjects];
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self clampScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    CGPoint location2ndFinger = [self clampScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location locationID:touch.locationID];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation locationID:touch.locationID]) {
                [utils performClickAt:screenLocation];
            }
            
            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            CGPoint prevLocation = [self clampScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
                         relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];

            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;

        case TUCCursorActionKeyboardShortcut:
            [self.delegate performKeyboardShortcutForGesture:gesture];
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }
    
    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMoveClickIfNeeded;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        case TUCCursorGestureLongPress:         return TUCCursorActionClick;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
            
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;
        case _TUCCursorGestureNone:             return TUCCursorActionNone;

        default:                                return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance locationID:(uint32_t)locationID {
    
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    CGFloat screenDistance = mmDistance * [screen pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance / screen.frame.size.width,
                                   screenDistance / screen.frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        if (t.locationID != locationID) return NO;

        CGFloat dx = [t location].x - point.x;
        CGFloat dy = [t location].y - point.y;

        return sqrt( pow(dx, 2) + pow(dy, 2) ) < distance.x;
    }];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}


/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
    //    if (touch.uuid == self.touchUsedForCursor.uuid) {
    //        [self processTouchesForCursorInput];
    //        self.touchUsedForCursor = nil;
    //    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d AND locationID == %u", contactID, locationID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID locationID:locationID includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID locationID:locationID];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];

    CGFloat rotation = screen.rotation;

    CGFloat extra = [[self delegate] digitizerRotationForLocationID:locationID];

    rotation += extra;
    rotation = fmod(rotation, 360);
    if (rotation < 0) {
        rotation += 360;
    }

    // Rotate the glass-relative point into the screen's content orientation.
    CGPoint rotated;
    if (rotation == 180) {
        rotated = CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
    } else if (rotation == 90) {
        rotated = CGPointMake(1 - devicePoint.y, devicePoint.x);
    } else if (rotation == 270) {
        rotated = CGPointMake(devicePoint.y, 1 - devicePoint.x);
    } else {
        rotated = devicePoint;
    }

    // Then account for any letterboxing when the content doesn't fill the panel (mirroring
    // a differently-shaped display). A no-op when the aspect ratios already match.
    return [screen convertGlassPointToContentPoint:rotated];
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    return [[self touchscreenForLocationID:locationID] convertPointRelativeToAbsolute:relativePoint];
}



- (CGPoint)clampScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    CGPoint clamped = [screen clampRelativePoint:relativePoint toEdgeInset:self.edgeDeadZone];
    return [screen convertPointRelativeToAbsolute:clamped];
}



- (TUCScreen *)touchscreenForLocationID:(uint32_t)locationID {
    if (self.delegate != nil) {
        return [self.delegate touchscreenForLocationID:locationID];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point locationID:(uint32_t)locationID {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];
    
    CGRect screenFrame = [self touchscreenForLocationID:locationID].frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isSystemChromeOwner:(pid_t)pid name:(NSString *)ownerName {
    static NSSet<NSString *> *chromeBundleIDs;
    static NSSet<NSString *> *chromeOwnerNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chromeBundleIDs = [NSSet setWithArray:@[
            @"com.apple.dock",
            @"com.apple.controlcenter",
            @"com.apple.notificationcenterui",
        ]];
        // The Window Server has no NSRunningApplication, so match it by owner name.
        chromeOwnerNames = [NSSet setWithArray:@[ @"Window Server", @"WindowServer" ]];
    });

    if (ownerName && [chromeOwnerNames containsObject:ownerName]) {
        return YES;
    }

    NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    return bundleID != nil && [chromeBundleIDs containsObject:bundleID];
}


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return NO;
    }

    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];

    CFArrayRef array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);

    // The window list is ordered front-to-back by window *level* (not grouped by app), so
    // high-level overlays — including our own screenSaver-level panels — come before the
    // active app's normal windows. `behindFrontmostWindow` flips once we pass the active
    // app's topmost window: windows seen before it are stacked above it, windows after are
    // behind it.
    BOOL behindFrontmostWindow = NO;
    BOOL res = NO;

    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);

        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;

        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);

        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }

        if (!isInside) continue;

        NSString *ownerName = (__bridge NSString *)CFDictionaryGetValue(dic, kCGWindowOwnerName);
        if ([self isSystemChromeOwner:currPID name:ownerName]) {
            continue;
        }

        // First real window under the point = the one the finger actually hits.
        if (isFrontmostApp) {
            res = NO;   // already the active window — the tap actuates it directly
        } else if (!behindFrontmostWindow) {
            res = NO;   // stacked above the active app (an overlay or our own panel) — takes the tap directly
        } else {
            // A background window of another app — normally inject a click to raise it.
            // Exception: the title bar. A background title bar accepts clicks directly, so
            // our injected raise-click plus the tap's own click would register as a
            // title-bar double-click (→ zoom/fullscreen). A single tap already raises the
            // window, so skip the extra click within the title-bar strip.
            //
            // CGWindowList can't tell us the actual title-bar/toolbar height, so this is a
            // heuristic constant. Erring high (toolbars on Tahoe are tall) costs at most a
            // missed raise-click near the top of a background window; erring low brings the
            // destructive double-click-zoom back.
            CGFloat titleBarHeight = 44;
            BOOL inTitleBar = (point.y - nextFrame.origin.y) <= titleBarHeight;
            res = inTitleBar ? NO : YES;
        }
        break;
    }

    CFRelease(array);
    return res;
}





#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.frameIDsByLocationID = [NSMutableDictionary new];
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
        self.stationaryThreshold = 0.1;
        self.edgeDeadZone = 0;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;

        self.threeFingerSwipesEnabled = NO;
        self.fourFingerSwipesEnabled = NO;
        self.swipeThreshold = 10;
        self.longPressDuration = 0.35;
        self.swipeStartPoints = [NSMutableDictionary new];
        self.swipeTrackedUUIDs = [NSMutableSet new];
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}



#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t locationID, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, uint32_t locationID, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withSize:size azimuth:azimuth];
}

void TouchInputManagerDidProcessReport(void *self, uint32_t locationID) {
    [(__bridge id)self didProcessReportForLocationID:locationID];
}

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didConnectTouchscreenWithLocationID:locationID];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didDisconnectTouchscreenWithLocationID:locationID];
}


@end
