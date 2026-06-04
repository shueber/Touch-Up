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

/// Opt-in: when enabled, the HID manager is (re)opened with exclusive access so macOS and other
/// apps stop receiving the matched devices' events. Toggling at runtime cycles the manager.
void SetTouchDevicesSeized(bool seize);

#endif /* HIDInterpreter_h */
