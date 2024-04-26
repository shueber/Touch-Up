//
//  TUCScreen.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/**
 The `TUCScreen` augments `NSScreen` with access to additional screen layout properties and information on the conversion of digitizer coordinate system to pixels.
 */
@interface TUCScreen : NSObject

@property NSUInteger id;
@property (strong) NSString *name;
@property CGFloat rotation;
@property CGSize physicalSize;
@property CGRect frame;

- (CGFloat)pixelsPerMM;
- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint;

- (nullable NSScreen *)systemScreen;

+ (NSArray *)allScreens;

@end

NS_ASSUME_NONNULL_END
