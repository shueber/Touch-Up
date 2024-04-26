//
//  TUCTouch.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN


typedef NS_OPTIONS(NSUInteger, TUCCursorGesture) {
    _TUCCursorGestureNone           = 0,       // internal, used if two finger gesture not identifed yet
    TUCCursorGestureTouchDown       = 1 << 1,
    TUCCursorGestureTap             = 1 << 2,
    TUCCursorGestureLongPress       = 1 << 3,
    TUCCursorGestureDrag            = 1 << 4,
    TUCCursorGestureHoldAndDrag     = 1 << 5,
    TUCCursorGestureTapSecondFinger = 1 << 6,
    TUCCursorGestureTwoFingerDrag   = 1 << 7,
    TUCCursorGesturePinch           = 1 << 8  // internal: pinch cannot be remapped
};


typedef NS_ENUM(NSUInteger, TUCCursorAction) {
    TUCCursorActionNone,
    TUCCursorActionMove,
    TUCCursorActionMoveClickIfNeeded,  // moves cursor: if location is not in frontmost window, click first to bring that to front
    TUCCursorActionPointAndClick, // like move, but clicks on release
    TUCCursorActionDrag,
    TUCCursorActionClick,
    TUCCursorActionSecondaryClick,
    TUCCursorActionScroll,
    TUCCursorActionMagnify
};



@interface TUCTouch : NSObject

@property (strong) NSUUID *uuid;
@property NSInteger contactID;

@property BOOL isOnSurface; //tip
@property BOOL confidenceFlag;

@property CGSize size;
@property CGFloat azimuth;

@property (nonatomic) NSTouchPhase phase;
@property NSTouchPhase previousPhase;

@property (nonatomic) CGPoint location;
@property CGPoint previousLocation;

@property NSInteger lastUpdated; // the page ID during last update


- (instancetype)initWithContactID:(NSInteger)contactID ;



- (BOOL)isActive;

- (NSComparisonResult) compareWithAnotherTouch:(TUCTouch*) anotherTouch;

- (CGPoint)trajectory;
- (CGPoint)trajectorySign;

@end

NS_ASSUME_NONNULL_END
