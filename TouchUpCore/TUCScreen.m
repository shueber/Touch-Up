//
//  TUCScreen.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import "TUCScreen.h"

@implementation TUCScreen

- (instancetype)initWithScreen:(NSScreen *)screen frameOfFirstScreen:(CGRect)firstFrame {
    if (self = [super init]) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        CGDirectDisplayID displayID = [number unsignedIntValue];
        
        self.id = displayID;
        
        self.rotation = CGDisplayRotation(displayID);
        
        
        self.physicalSize = CGDisplayScreenSize(displayID);
        
        
        CGRect thisFrame = screen.frame;
        // need to flip coordinate system
        self.frame = CGRectMake(thisFrame.origin.x,
                                thisFrame.origin.y + thisFrame.size.height - firstFrame.size.height,
                                thisFrame.size.width,
                                thisFrame.size.height);
        
        
        if (@available(macOS 10.15, *)) {
            self.name = [screen localizedName];
        } else {
            // Fallback on earlier versions
            self.name =  [NSString stringWithFormat: @"Display %u", displayID];
        }
        
    }
    
    return self;
}

- (nullable NSScreen *)systemScreen {
    NSArray *screens = [NSScreen screens];
    
    for (NSScreen *screen in screens) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        CGDirectDisplayID displayID = [number unsignedIntValue];
        if (displayID == self.id) {
            return screen;
        }
    }
    return nil;
}


- (CGFloat)pixelsPerMM {
    return self.frame.size.width / self.physicalSize.width;
}

- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint {
    CGPoint screenOrigin = self.frame.origin;
    CGSize screenSize = self.frame.size;
    
    
    CGPoint absLoc = CGPointMake(relativePoint.x * screenSize.width + screenOrigin.x,
                                 relativePoint.y * screenSize.height - screenOrigin.y);
    
    return absLoc;
}



- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"<[TUFScreen ID %ld] Frame: %@, Name: %@>", self.id, NSStringFromRect(self.frame), self.name];
}

+ (NSArray *)allScreens {
    NSMutableArray<TUCScreen *> *myScreens = [NSMutableArray array];
    
    NSArray *nsScreens = [NSScreen screens];
    
    CGRect firstFrame = CGRectZero;
    if ([nsScreens count] > 0) {
        NSScreen  *firstScreen = [nsScreens objectAtIndex:0];
        firstFrame = firstScreen.frame;
    }
    
    for (NSScreen *screen in nsScreens) {
        TUCScreen *e = [[TUCScreen alloc] initWithScreen:screen
                                      frameOfFirstScreen:firstFrame];
        [myScreens addObject:e];
    }
    
    return myScreens;
}

@end
