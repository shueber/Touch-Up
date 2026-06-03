//
//  HIDInterpreter.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#ifndef HIDInterpreter_h
#define HIDInterpreter_h

#include <stdio.h>
#include <stdbool.h>

void OpenHIDManager(void *delegate);

void CloseHIDManager(void);

/// Opt-in: when enabled, accepted touch interfaces are opened exclusively (seized) so
/// macOS and other apps stop receiving their events — Touch Up becomes the sole handler.
/// Applies to currently-connected and future devices. Pen interfaces stay shared.
void SetTouchDevicesSeized(bool seize);

#endif /* HIDInterpreter_h */
