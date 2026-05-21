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

- (CGFloat)digitizerRotationForLocationID:(uint32_t)locationID;

@end

NS_ASSUME_NONNULL_END
