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
@property BOOL cursorTouchDidDrag;
@property (strong) NSDate *cursorTouchStationarySinceDate;
@property CGPoint cursorTouchInitialLocation;
@property BOOL suppressCursorInputUntilAllTouchesEnd;

@property CGFloat pinchDistance;

@property TUCCursorGesture identifiedMultitouchGesture;

- (NSArray<TUCTouch *> *)windowsGestureTouchesFromTouches:(NSArray<TUCTouch *> *)touches cursorTouch:(TUCTouch *)cursorTouch;
- (CGFloat)distanceInMillimetersBetweenRelativePoint:(CGPoint)p1 and:(CGPoint)p2 locationID:(uint32_t)locationID;

@end


@implementation TUCTouchInputManager

- (void)setLogTouchEvents:(BOOL)logTouchEvents {
    _logTouchEvents = logTouchEvents;
    [TUCCursorUtilities sharedInstance].logCursorEvents = logTouchEvents;
    SetHIDEventLogging(logTouchEvents);
}

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


- (void)clearCursorTouchState {
    self.cursorTouch = nil;
    self.gestureAdditionalTouch = nil;
    self.cursorTouchQualifiedForTap = NO;
    self.cursorTouchDidHold = NO;
    self.cursorTouchDidDrag = NO;
    self.cursorTouchStationarySinceDate = nil;
    self.suppressCursorInputUntilAllTouchesEnd = NO;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    CGPoint convertedPoint = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID];
    CGPoint point = [self calibratedRelativePointForPoint:convertedPoint locationID:locationID];
    if (self.logTouchEvents) {
        NSLog(@"TouchUp touch input locationID=0x%08x contact=%ld raw=%@ converted=%@ calibrated=%@ onSurface=%d confidence=%d",
              locationID,
              (long)contactID,
              NSStringFromPoint(digitizerPoint),
              NSStringFromPoint(convertedPoint),
              NSStringFromPoint(point),
              isOnSurface,
              confidenceFlag);
    }
    
    TUCTouch *existingActiveTouch = [self findTouchWithID:contactID locationID:locationID includingPastTouches:NO];
    if (!isOnSurface && existingActiveTouch == nil) {
        if (self.logTouchEvents) {
            NSLog(@"TouchUp ignored stale lift locationID=0x%08x contact=%ld",
                  locationID,
                  (long)contactID);
        }
        return;
    }

    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchDidDrag = NO;
        self.cursorTouchStationarySinceDate = nil;
        self.cursorTouchInitialLocation = point;
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
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = [self touchscreenForLocationID:locationID].nativePhysicalSize.width;
        //TODO: - Make customizable in settings?
        BOOL isStationary = (digitizerRelDistance * screenSize) < 0.1;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == self.cursorTouch.uuid) {
            if (!isStationary) {
                CGFloat tapTravel = [self distanceInMillimetersBetweenRelativePoint:touch.location
                                                                                and:self.cursorTouchInitialLocation
                                                                         locationID:locationID];
                BOOL exceededTapMovementTolerance = tapTravel > self.tapMovementTolerance;
                if (!self.usesWindowsTouchMode || exceededTapMovementTolerance) {
                    self.cursorTouchQualifiedForTap = NO;
                    self.cursorTouchStationarySinceDate = nil;
                }
                if (self.usesWindowsTouchMode && exceededTapMovementTolerance) {
                    self.cursorTouchDidDrag = YES;
                }
                if (self.logTouchEvents && self.usesWindowsTouchMode) {
                    NSLog(@"TouchUp tap candidate travel=%.2fmm threshold=%.2fmm qualified=%d",
                          tapTravel,
                          self.tapMovementTolerance,
                          self.cursorTouchQualifiedForTap);
                }
                
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
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;

    if ([self processWindowsMultitouchForTouches:touches cursorTouch:cursorTouch]) {
        return;
    }
    
    
    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && !self.cursorTouchDidHold && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
            if (self.usesWindowsTouchMode) {
                self.cursorTouchQualifiedForTap = NO;
            }
        }
        
        if (!self.usesWindowsTouchMode) {
            [self checkForSecondaryClick];
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.cursorTouchDidHold) {
                if (self.usesWindowsTouchMode && !self.cursorTouchDidDrag) {
                    [self performMouseEventForGesture:TUCCursorGestureLongPress];
                } else {
                    [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
                }
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

        [self clearCursorTouchState];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        [self clearCursorTouchState];
        return;
    }
    
    if (!self.usesWindowsTouchMode && [self checkForSecondaryClick]) {
        return;
    }
    
    if (!self.usesWindowsTouchMode && [touches count] == 2 && [touches containsObject: cursorTouch]) {
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
        if (!self.usesWindowsTouchMode || self.cursorTouchDidDrag) {
            [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
        }
    } else if (self.usesWindowsTouchMode && self.cursorTouchQualifiedForTap) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


- (BOOL)processWindowsMultitouchForTouches:(NSArray<TUCTouch *> *)touches cursorTouch:(TUCTouch *)cursorTouch {
    if (!self.usesWindowsTouchMode) {
        return NO;
    }

    NSArray<TUCTouch *> *gestureTouches = [self windowsGestureTouchesFromTouches:touches cursorTouch:cursorTouch];
    NSUInteger activeTouchCount = [gestureTouches count];
    if (activeTouchCount > 1) {
        self.suppressCursorInputUntilAllTouchesEnd = YES;
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchDidDrag = YES;
        [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    }

    if (!self.suppressCursorInputUntilAllTouchesEnd) {
        return NO;
    }

    if (activeTouchCount == 0) {
        [self stopCurrentGesture];
        [self clearCursorTouchState];
        return YES;
    }

    if (activeTouchCount != 2 || ![gestureTouches containsObject:cursorTouch]) {
        [self stopCurrentGesture];
        return YES;
    }

    TUCTouch *otherTouch = gestureTouches[1];
    if (otherTouch.uuid == cursorTouch.uuid) {
        otherTouch = gestureTouches[0];
    }

    self.gestureAdditionalTouch = otherTouch;

    BOOL cursorMoved = [self touchMovedInCurrentFrame:cursorTouch];
    BOOL otherMoved = [self touchMovedInCurrentFrame:otherTouch];
    BOOL shouldScroll = cursorMoved || otherMoved;

    if (self.logTouchEvents) {
        NSLog(@"TouchUp windows multitouch active=%lu cursorPhase=%@ otherPhase=%@ cursorMoved=%d otherMoved=%d",
              (unsigned long)activeTouchCount,
              [self stringForPhase:cursorTouch.phase],
              [self stringForPhase:otherTouch.phase],
              cursorMoved,
              otherMoved);
    }

    if (shouldScroll) {
        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
        [self performMouseEventForGesture:TUCCursorGestureTwoFingerDrag];
    }

    return YES;
}


- (NSArray<TUCTouch *> *)windowsGestureTouchesFromTouches:(NSArray<TUCTouch *> *)touches cursorTouch:(TUCTouch *)cursorTouch {
    if (self.windowsTouchModeSingleFingerDistance <= 0 ||
        cursorTouch == nil ||
        ![touches containsObject:cursorTouch]) {
        return touches;
    }

    NSMutableArray<TUCTouch *> *gestureTouches = [NSMutableArray arrayWithObject:cursorTouch];

    for (TUCTouch *touch in touches) {
        if (touch.uuid == cursorTouch.uuid) {
            continue;
        }

        if (touch.locationID != cursorTouch.locationID) {
            [gestureTouches addObject:touch];
            continue;
        }

        CGFloat distance = [self distanceInMillimetersBetweenRelativePoint:touch.location
                                                                       and:cursorTouch.location
                                                                locationID:cursorTouch.locationID];
        if (distance < self.windowsTouchModeSingleFingerDistance) {
            if (self.logTouchEvents) {
                NSLog(@"TouchUp windows multitouch treating close contact as one finger distance=%.2f threshold=%.2f",
                      distance,
                      self.windowsTouchModeSingleFingerDistance);
            }
            continue;
        }

        [gestureTouches addObject:touch];
    }

    return gestureTouches;
}


- (BOOL)touchMovedInCurrentFrame:(TUCTouch *)touch {
    if (touch == nil || touch.phase != NSTouchPhaseMoved) {
        return NO;
    }
    NSInteger currentFrameID = [self currentFrameIDForLocationID:touch.locationID];
    // didProcessReportForLocationID advances the frame before cursor processing.
    return touch.lastUpdated == currentFrameID || touch.lastUpdated + 1 == currentFrameID;
}


- (CGPoint)screenTranslationForTouch:(TUCTouch *)touch {
    CGPoint currentLocation = [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    CGPoint previousLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
    return CGPointMake(currentLocation.x - previousLocation.x,
                       currentLocation.y - previousLocation.y);
}


- (CGPoint)scrollTranslationForGesture:(TUCCursorGesture)gesture touch:(TUCTouch *)touch screenLocation:(CGPoint)screenLocation {
    if (self.usesWindowsTouchMode &&
        gesture == TUCCursorGestureTwoFingerDrag &&
        self.gestureAdditionalTouch != nil) {
        CGPoint translation = CGPointZero;
        CGFloat contributingTouches = 0;
        NSArray<TUCTouch *> *scrollTouches = @[touch, self.gestureAdditionalTouch];

        for (TUCTouch *scrollTouch in scrollTouches) {
            if (![self touchMovedInCurrentFrame:scrollTouch]) {
                continue;
            }

            CGPoint touchTranslation = [self screenTranslationForTouch:scrollTouch];
            translation.x += touchTranslation.x;
            translation.y += touchTranslation.y;
            contributingTouches += 1;
        }

        if (contributingTouches > 0) {
            return CGPointMake(translation.x / contributingTouches,
                               translation.y / contributingTouches);
        }
    }

    CGPoint previousLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
    return CGPointMake(screenLocation.x - previousLocation.x,
                       screenLocation.y - previousLocation.y);
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


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location locationID:touch.locationID];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];

    if (self.logTouchEvents) {
        NSLog(@"TouchUp gesture=%@ action=%@ phase=%@ locationID=0x%08x rel=%@ abs=%@ clickZone=%.2f",
              [self stringForGesture:gesture],
              [self stringForAction:action],
              [self stringForPhase:touch.phase],
              touch.locationID,
              NSStringFromPoint(touch.location),
              NSStringFromPoint(screenLocation),
              doubleClickSpan);
    }
    
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
            CGPoint translation = [self scrollTranslationForGesture:gesture touch:touch screenLocation:screenLocation];
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


- (CGFloat)distanceInMillimetersBetweenRelativePoint:(CGPoint)p1 and:(CGPoint)p2 locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    CGFloat dx = (p1.x - p2.x) * screen.nativePhysicalSize.width;
    CGFloat dy = (p1.y - p2.y) * screen.nativePhysicalSize.height;
    return hypot(dx, dy);
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


- (CGPoint)calibratedRelativePointForPoint:(CGPoint)point locationID:(uint32_t)locationID {
    CGPoint result = point;
    if (self.delegate != nil && [self.delegate respondsToSelector:@selector(calibratedRelativePoint:forLocationID:)]) {
        result = [self.delegate calibratedRelativePoint:point forLocationID:locationID];
    }

    result.x = MAX(0.0, MIN(1.0, result.x));
    result.y = MAX(0.0, MIN(1.0, result.y));
    return result;
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    return [[self touchscreenForLocationID:locationID] convertPointRelativeToAbsolute:relativePoint];
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
        self.tapMovementTolerance = 3;
        self.windowsTouchModeSingleFingerDistance = 0;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
        self.usesWindowsTouchMode = NO;
        self.logTouchEvents = NO;
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


#pragma mark - Logging

- (NSString *)stringForPhase:(NSTouchPhase)phase {
    switch (phase) {
        case NSTouchPhaseBegan: return @"began";
        case NSTouchPhaseMoved: return @"moved";
        case NSTouchPhaseStationary: return @"stationary";
        case NSTouchPhaseEnded: return @"ended";
        case NSTouchPhaseCancelled: return @"cancelled";
        default: return [NSString stringWithFormat:@"phase-%lu", (unsigned long)phase];
    }
}

- (NSString *)stringForGesture:(TUCCursorGesture)gesture {
    switch (gesture) {
        case TUCCursorGestureTouchDown: return @"touchDown";
        case TUCCursorGestureTap: return @"tap";
        case TUCCursorGestureLongPress: return @"longPress";
        case TUCCursorGestureDrag: return @"drag";
        case TUCCursorGestureHoldAndDrag: return @"holdAndDrag";
        case TUCCursorGestureTapSecondFinger: return @"tapSecondFinger";
        case TUCCursorGestureTwoFingerDrag: return @"twoFingerDrag";
        case TUCCursorGesturePinch: return @"pinch";
        case _TUCCursorGestureNone: return @"none";
    }
}

- (NSString *)stringForAction:(TUCCursorAction)action {
    switch (action) {
        case TUCCursorActionNone: return @"none";
        case TUCCursorActionMove: return @"move";
        case TUCCursorActionMoveClickIfNeeded: return @"moveClickIfNeeded";
        case TUCCursorActionPointAndClick: return @"pointAndClick";
        case TUCCursorActionDrag: return @"drag";
        case TUCCursorActionClick: return @"click";
        case TUCCursorActionSecondaryClick: return @"secondaryClick";
        case TUCCursorActionScroll: return @"scroll";
        case TUCCursorActionMagnify: return @"magnify";
    }
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
