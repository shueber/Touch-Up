//
//  Touch.h
//  HID Touch Input
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Touch : NSObject

@property NSInteger contactID;

@property BOOL isOnSurface; //tip

@property CGSize size;
@property CGFloat azimuth;
@property BOOL isValid;
@property NSInteger scanTime;

@property (nonatomic) NSTouchPhase phase;
@property NSTouchPhase previousPhase;

@property (nonatomic) CGPoint location;
@property CGPoint previousLocation;

@property NSInteger lastUpdated; // the page ID during last update

- (NSComparisonResult) compareWithAnotherTouch:(Touch*) anotherTouch;

- (instancetype)initWithContactID:(NSInteger)contactID pageID:(NSInteger)pageID ;

- (BOOL)isActive;

@end

NS_ASSUME_NONNULL_END
