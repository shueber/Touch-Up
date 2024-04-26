//
//  Touch.m
//  HID Touch Input
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "Touch.h"

@implementation Touch

- (instancetype)initWithContactID:(NSInteger)contactID pageID:(NSInteger)pageID {
    if (self = [super init]) {
        
        self.contactID = contactID;
        self.location = CGPointZero;
        self.isOnSurface = true;
        
        self.size = CGSizeZero;
        self.azimuth = 0;
        self.isValid = true;
        self.scanTime = 0;
        
        _previousPhase = NSTouchPhaseBegan;
        _phase = NSTouchPhaseBegan;
        
        _previousLocation = CGPointZero;
        _location = CGPointZero;
        
        self.lastUpdated = pageID;
        
        
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


- (BOOL)isActive {
    return _phase != NSTouchPhaseEnded && _phase != NSTouchPhaseCancelled;
}


- (NSComparisonResult) compareWithAnotherTouch:(Touch*) anotherTouch {
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
