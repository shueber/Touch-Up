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
 How long the user has to hold before a drag gesture turns into holdAndDrag.
 */
@property NSTimeInterval holdDuration;

/**
 The maximum distance in mm a touch may travel between two reports while still counting as
 stationary. Larger values tolerate more finger jitter before a touch is treated as moving
 (which is what disqualifies a tap and starts a drag).
 */
@property CGFloat stationaryThreshold;

/**
 Width in points of a border along each screen edge in which the cursor is never posted.
 Touches inside this border are pushed inwards to its inner edge. The default value is 0 (off).
 */
@property CGFloat edgeDeadZone;

/**
 If a touch is no longer reported by the screen, wait for this number of incoming reports bevore deleting it from the touch set.
 */
@property NSInteger errorResistance;


/**
 If a touchscreen sometimes sends invalid touch data at location (0,0), activate this option to ignore them
 */
@property BOOL ignoreOriginTouches;


- (void)start;

- (void)stop;


/**
 Opt-in exclusive access. When YES, connected touchscreens are seized so macOS and other
 apps no longer receive their events — Touch Up becomes the sole handler. Default is NO.
 Applies immediately to currently-connected devices and  future connections.
 */
- (void)setTouchscreensSeized:(BOOL)seized;



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID;


- (void)triggerSystemAccessibilityAccessAlert;

@end

NS_ASSUME_NONNULL_END
