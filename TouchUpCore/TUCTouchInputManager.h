//
//  TUCTouchInputManager.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <TouchUpCore/TUCTouchInputManager-C.h>
#import <TouchUpCore/TUCTouchDelegate.h>
#import <TouchUpCore/TUCTouch.h>

NS_ASSUME_NONNULL_BEGIN



@interface TUCTouchInputManager : NSObject

@property (weak, nonatomic) id<TUCTouchDelegate> delegate;

@property (strong, atomic) NSMutableSet<TUCTouch *> *touchSet;

/**
 Allows to deactiate that the framework processes touches to post them as mouse events.
 The default value is YES.
 */
@property BOOL postMouseEvents;


/**
 The maximal distance in mm that two taps may be apart from each other to count as double click
 */
@property CGFloat doubleClickTolerance;

/**
 The maximal movement in mm that still lets a Windows-style touch count as a tap.
 */
@property CGFloat tapMovementTolerance;

/**
 In Windows Touch Mode, contacts closer than this threshold are treated as one
 finger instead of starting a two-finger gesture. Set to 0 to disable.
 */
@property CGFloat windowsTouchModeSingleFingerDistance;

/**
 How long the user has to hold before a drag gesture turns into holdAndDrag.
 */
@property NSTimeInterval holdDuration;

/**
 If a touch is no longer reported by the screen, wait for this number of incoming reports bevore deleting it from the touch set.
 */
@property NSInteger errorResistance;


/**
 If a touchscreen sometimes sends invalid touch data at location (0,0), activate this option to ignore them
 */
@property BOOL ignoreOriginTouches;


/**
 If enabled, gestures are interpreted closer to a direct Windows-style
 touchscreen: tap clicks on release, long press secondary-clicks, one-finger
 movement drags, and two-finger movement scrolls. The default value is NO.
 */
@property BOOL usesWindowsTouchMode;


/**
 If enabled, logs touch coordinate conversion, gesture selection, cursor actions,
 and click counts to the system log. The default value is NO.
 */
@property (nonatomic) BOOL logTouchEvents;


- (void)start;

- (void)stop;


/**
 Opt-in exclusive access. When YES, connected touchscreens are seized so macOS and other
 apps no longer receive their events — Touch Up becomes the sole handler. Pen interfaces of
 combo digitizers stay shared, so the pen keeps working through macOS. Default is NO.
 Applies immediately to currently-connected devices and to future connections.
 */
- (void)setTouchscreensSeized:(BOOL)seized;



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID;


- (void)triggerSystemAccessibilityAccessAlert;

@end

NS_ASSUME_NONNULL_END
