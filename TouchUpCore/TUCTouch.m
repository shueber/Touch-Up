//
//  TUCTouch.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouch.h"

@implementation TUCTouch

- (instancetype)initWithContactID:(NSInteger)contactID {
    if (self = [super init]) {
        
        _uuid = [NSUUID UUID];
        
        _contactID = contactID;
        
        _location = CGPointZero;
        
        _isOnSurface = true;
        _confidenceFlag = false;
        
        _size = CGSizeZero;
        _azimuth = 0;
        
        
        _lastUpdated = 0;
        
        
        _phase = NSTouchPhaseBegan;
        _previousPhase = NSTouchPhaseBegan;
        
        _location = CGPointZero;
        _previousLocation = CGPointZero;
    }
    return self;
}




@synthesize phase = _phase;

- (NSTouchPhase)phase {
    return _phase;
}

- (void)setPhase:(NSTouchPhase)phase {
    _previousPhase = _phase;
    _phase = phase;
}


@synthesize location = _location;

- (CGPoint)location {
    return _location;
}

- (void)setLocation:(CGPoint)location {
    _previousLocation = _location;
    _location = location;
}



#pragma mark - Gesture Detection


- (CGPoint)trajectory {
    CGPoint p1 = [self location];
    CGPoint p2 = [self previousLocation];
    return CGPointMake(p1.x - p2.x,
                       p1.y - p2.y);
}

- (CGPoint)trajectorySign {
    CGPoint p = [self trajectory];
    return CGPointMake(p.x < 0 ? -1 : p.x > 0 ? 1 : 0,
                       p.y < 0 ? -1 : p.y > 0 ? 1 : 0);
}


#pragma mark - Utility
- (BOOL)isActive {
    return _phase != NSTouchPhaseEnded && _phase != NSTouchPhaseCancelled;
}


- (NSComparisonResult) compareWithAnotherTouch:(TUCTouch*) anotherTouch {
    return [[NSNumber numberWithInteger:self.contactID] compare:[NSNumber numberWithInteger:anotherTouch.contactID]];
}


- (NSString *)debugDescription {
    NSString *phase;
    if (self.phase == NSTouchPhaseBegan) {
        phase = @"Began";
    } else if (self.phase == NSTouchPhaseMoved) {
        phase = @"Moved";
    } else if (self.phase == NSTouchPhaseStationary) {
        phase = @"Stationary";
    } else if (self.phase == NSTouchPhaseEnded) {
        phase = @"Ended";
    } else if (self.phase == NSTouchPhaseCancelled) {
        phase = @"Cancelled";
    } else {
        phase = [NSString stringWithFormat:@"Phase %ld", self.phase];
    }
    
    return [NSString stringWithFormat:@"Touch %ld: Location: %@ Phase:%@  OnSurface:%@", self.contactID, NSStringFromPoint(self.location), phase, [NSNumber numberWithBool:self.isOnSurface]];
}

@end
