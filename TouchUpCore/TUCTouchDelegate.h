//
//  TUCTouchDelegate.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TouchUpCore/TUCTouch.h>
#import <TouchUpCore/TUCScreen.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TUCTouchDelegate <NSObject>

#pragma mark - Touch Data
/**
 
 This method is called every time after the `touchSet` was updated
 */
- (void)touchesDidChange;



#pragma mark - Lifecycle

- (void)touchscreenDidConnectWithLocationID:(uint32_t)locationID;
- (void)touchscreenDidDisconnectWithLocationID:(uint32_t)locationID;



#pragma mark - Mouse Control

/**
 Specifies which screen corresponds to the touch screen with the given location ID.
 */
- (nullable TUCScreen *)touchscreenForLocationID:(uint32_t)locationID;

/**
 Used to customize which mouse events are posted by the input manager.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture;

/**
 Called exactly once per gesture when a multi-finger swipe was recognized and
 `actionForGesture:` answered with TUCCursorActionKeyboardShortcut. The delegate
 is responsible for posting the keyboard shortcut that is mapped to the gesture.
 */
- (void)performKeyboardShortcutForGesture:(TUCCursorGesture)gesture;

/**
 Called when a long-press gesture (three or four fingers held still) is recognized.
 The delegate should press the key mapped to the gesture and keep it held.
 `endKeyboardHoldForGesture:` fires once every finger of the session has lifted.
 */
- (void)beginKeyboardHoldForGesture:(TUCCursorGesture)gesture;
- (void)endKeyboardHoldForGesture:(TUCCursorGesture)gesture;

- (CGFloat)digitizerRotationForLocationID:(uint32_t)locationID;

@end

NS_ASSUME_NONNULL_END
