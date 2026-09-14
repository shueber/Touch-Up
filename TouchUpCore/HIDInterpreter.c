//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include "TUCTouchInputManager-C.h"

#include <mach/mach_port.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include <CoreGraphics/CoreGraphics.h>

#pragma mark - Per-Device State

#define kMaxTouchscreens 4

typedef struct {
    IOHIDDeviceRef          device;     // unique identity of this HID interface
    uint32_t                locationID; // shared across interfaces of the same USB device
    CFIndex                 contactCollectionCount; // how many real multitouch contacts this interface reports
    Boolean                 isActive;
    Boolean                 seized;     // whether we hold an exclusive (seized) open on this device

    IOHIDQueueRef           queue;
    Boolean                 areElementRefsSet;
    
    IOHIDElementRef         applicationCollectionElement;
    IOHIDElementRef         scanTimeElement;
    CFMutableArrayRef       touchCollectionElements;
    
    /**
     stores values for the touch collections: cookie -> latest value
     in hybrid mode (especially if order of touches moves) this data has to be set to last state per collection element receiving touches now
     */
    CFMutableDictionaryRef  storedInputValues;
    
    CFMutableArrayRef       contactIdentifiers;
    
    CFIndex                 contactCount;
    CFIndex                 hybridOffset;
    Boolean                 touchscreenUsesHybridMode;
} HIDDeviceState;

static HIDDeviceState gDevices[kMaxTouchscreens];
static int gDeviceCount = 0;

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

// When true, accepted touch interfaces are opened exclusively (seized) so macOS and other
// apps no longer receive their events — Touch Up becomes the sole handler. Opt-in.
static Boolean gSeizeTouchDevices = false;


#pragma mark - Device State Management


// State is keyed by the IOHIDDeviceRef, not the locationID: a combo digitizer presents
// several HID interfaces that all share one locationID, so the device ref is the only
// reliable per-interface identity.
HIDDeviceState* DeviceStateForRef(IOHIDDeviceRef device) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            return &gDevices[i];
        }
    }
    return NULL;
}

// Returns the single interface we've accepted as *the* touchscreen for this locationID
// (the one with the most contact collections), or NULL if none is registered yet.
HIDDeviceState* RegisteredDeviceForLocationID(uint32_t locationID) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].locationID == locationID) {
            return &gDevices[i];
        }
    }
    return NULL;
}


HIDDeviceState* AllocateDeviceState(IOHIDDeviceRef device, uint32_t locationID) {
    if (gDeviceCount >= kMaxTouchscreens) {
        fprintf(stderr, "Maximum number of touchscreens (%d) reached.\n", kMaxTouchscreens);
        return NULL;
    }

    HIDDeviceState *state = &gDevices[gDeviceCount];
    memset(state, 0, sizeof(HIDDeviceState));

    state->device = device;
    state->locationID = locationID;
    state->isActive = TRUE;
    state->contactCount = 1;
    state->touchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->contactIdentifiers = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->storedInputValues = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    gDeviceCount++;
    return state;
}


void DeallocateDeviceState(IOHIDDeviceRef device) {
    int index = -1;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            index = i;
            break;
        }
    }
    if (index < 0) return;
    
    HIDDeviceState *state = &gDevices[index];

    if (state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }

    if (state->queue) {
        IOHIDQueueStop(state->queue);
        IOHIDQueueUnscheduleFromRunLoop(state->queue, gRunLoopRef, kCFRunLoopCommonModes);
        CFRelease(state->queue);
    }
    if (state->touchCollectionElements) CFRelease(state->touchCollectionElements);
    if (state->contactIdentifiers) CFRelease(state->contactIdentifiers);
    if (state->storedInputValues) CFRelease(state->storedInputValues);
    
    // move last element into gap to keep array compact
    gDeviceCount--;
    if (index < gDeviceCount) {
        gDevices[index] = gDevices[gDeviceCount];
    }
    memset(&gDevices[gDeviceCount], 0, sizeof(HIDDeviceState));
}


#pragma mark General Debug Utilities




void PrintAddress(UInt8 *ptr, UInt64 length) {
    for (int i=0; i<length; i++) {
        printf("%02x ", ptr[i]);
        if ((i+1)%8 == 0) printf("  ");
        if ((i+1)%32 == 0) printf("\n");
    }
    printf("\n");
}


void PrintInput(IOHIDValueRef inHIDValue) {
    IOHIDElementRef elem = IOHIDValueGetElement(inHIDValue);
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    CFIndex value = IOHIDValueGetIntegerValue(inHIDValue);
    
    IOHIDElementCookie cookie = IOHIDElementGetCookie(elem);
    
    char pageDescr[6]  = "(---)";
    char usageDescr[10] = "(-------)";
    
    if (page == kHIDPage_GenericDesktop) {
        strcpy(pageDescr, "(GD) ");
        if (usage == kHIDUsage_GD_X) {
            strcpy(usageDescr, "(X)      ");
        } else if (usage == kHIDUsage_GD_Y) {
            strcpy(usageDescr, "(Y)      ");
        }
        
    } else if (page == kHIDPage_Digitizer) {
        strcpy(pageDescr, "(Dig)");
        
        if (usage == kHIDUsage_Dig_TipSwitch) {
            strcpy(usageDescr, "(Tip)    ");
        } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
            strcpy(usageDescr, "(Cont ID)");
        } else if (usage == kHIDUsage_Dig_ContactCount) {
            strcpy(usageDescr, "(ContCnt)");
        } else if (usage == kHIDUsage_Dig_TouchValid) {
            strcpy(usageDescr, "(IsValid)");
        } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
            strcpy(usageDescr, "(ScnTime)");
        } else if (usage == kHIDUsage_Dig_Width) {
            strcpy(usageDescr, "(Width)  ");
        } else if (usage == kHIDUsage_Dig_Height) {
            strcpy(usageDescr, "(Height) ");
        } else if (usage == kHIDUsage_Dig_Azimuth) {
            strcpy(usageDescr, "(Azimuth)");
        }
    }
    
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex lMax = IOHIDElementGetLogicalMax(elem);
    
    printf("%u\t| %#02lx %s\t| %#02lx %s\t|%8ld\t(%ld-%ld)\n", cookie, page, pageDescr, usage, usageDescr, value, lMin, lMax);
}





#pragma mark - Storing Values


uint32_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(HIDDeviceState *device, IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    uint32_t hash = StorageKeyForElement(element);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hash);
    
    if (CFDictionaryContainsKey(device->storedInputValues, key)) {
        CFIndex value;
        CFNumberRef num = CFDictionaryGetValue(device->storedInputValues, key);
        CFNumberGetValue(num, kCFNumberCFIndexType, &value);
        CFRelease(key);
        return value;
        
    }
    CFRelease(key);
    return kCFNotFound;
    
}



void StoreInputValue(HIDDeviceState *device, IOHIDValueRef hidValue) {
    
    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    IOHIDElementRef elem = IOHIDValueGetElement(hidValue);
    
    uint32_t keyValue = StorageKeyForElement(elem);
    
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyValue);
    
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &value);
    
    CFDictionarySetValue(device->storedInputValues, key, num);
    
    CFRelease(num);
    CFRelease(key);
    
    
    // special case: contact count could be zero in hybrid mode
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    
    if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
        // hybrid mode can only exist if the old value is larger than the number of collections that can be communicated at once
        CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
        
        if (device->contactCount > numCollections && value == 0 && device->hybridOffset > 0) {
            device->touchscreenUsesHybridMode = TRUE;
            
        } else {
            device->contactCount = value;
            device->hybridOffset = 0;
        }
    }
}




static IOHIDElementRef TouchscreenCollectionForElement(IOHIDElementRef element) {
  while (element) {
    if (IOHIDElementGetType(element) == kIOHIDElementTypeCollection &&
        IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication &&
        IOHIDElementGetUsagePage(element) == kHIDPage_Digitizer &&
        IOHIDElementGetUsage(element) == kHIDUsage_Dig_TouchScreen) {
      return element;
    }
    element = IOHIDElementGetParent(element);
  }
  return NULL;
}

static Boolean IsContactCollection(IOHIDElementRef element) {
  if (IOHIDElementGetType(element) != kIOHIDElementTypeCollection ||
      IOHIDElementGetCollectionType(element) != kIOHIDElementCollectionTypeLogical) {
    return false;
  }
  CFArrayRef children = IOHIDElementGetChildren(element);
  for (CFIndex i = 0; children && i < CFArrayGetCount(children); i++) {
    IOHIDElementRef child = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
    if (IOHIDElementGetUsagePage(child) == kHIDPage_Digitizer &&
        IOHIDElementGetUsage(child) == kHIDUsage_Dig_ContactIdentifier) {
      return true;
    }
  }
  return false;
}

// A finger value is nested in a logical collection. Walk all the way to its
// touchscreen application; pen/vendor applications on the same interface are unrelated.
void IdentifyElements(HIDDeviceState *device, IOHIDElementRef anyElement, Boolean printTree) {
    IOHIDElementRef applicationCollection = TouchscreenCollectionForElement(anyElement);
    if (!applicationCollection) return;

    CFArrayRemoveAllValues(device->touchCollectionElements);
    device->scanTimeElement = NULL;
    device->applicationCollectionElement = applicationCollection;
    
    
    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = children ? CFArrayGetCount(children) : 0;
    
    if (printTree) {
        printf("# touchscreen application has %ld children:\n", numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        if (IsContactCollection(element)) {
            CFArrayAppendValue(device->touchCollectionElements, element);
            
            if (printTree) {
                printf(" > Logical collection %ld\n", i);
                CFArrayRef grandchildren = IOHIDElementGetChildren(element);
                for( CFIndex j=0; j<CFArrayGetCount(grandchildren); j++) {
                    IOHIDElementRef gch = (IOHIDElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                    CFIndex page = IOHIDElementGetUsagePage(gch);
                    CFIndex usage = IOHIDElementGetUsage(gch);
                    CFIndex cookie= IOHIDElementGetCookie(gch);
                    
                    printf("    > %#02lx %#02lx  [%ld]\n", page, usage, cookie);
                }
            }
            
        } // logical collection
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
            if (printTree) {
                printf(" > Contact Count\n");
            }
        }
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_RelativeScanTime) {
            device->scanTimeElement = element;
            if (printTree) {
                printf(" > Scan Time\n");
            }
        }
        
        else {
            if (printTree) {
                printf(" > %#02lx %#02lx\n", page, usage);
            }
        }
    }
    device->areElementRefsSet = CFArrayGetCount(device->touchCollectionElements) > 0;
}









#pragma mark - Propagate Touch Data to next layer


void PrintTouchCollection(HIDDeviceState *device, IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex cookie = IOHIDElementGetCookie(element);
        CFIndex value = ValueOfElement(device, element);
        
        char pageDescr[6]  = "(---)";
        char usageDescr[10] = "(-------)";
        
        if (page == kHIDPage_GenericDesktop) {
            strcpy(pageDescr, "(GD) ");
            if (usage == kHIDUsage_GD_X) {
                strcpy(usageDescr, "(X)      ");
            } else if (usage == kHIDUsage_GD_Y) {
                strcpy(usageDescr, "(Y)      ");
            }
            
        } else if (page == kHIDPage_Digitizer) {
            strcpy(pageDescr, "(Dig)");
            
            if (usage == kHIDUsage_Dig_TipSwitch) {
                strcpy(usageDescr, "(Tip)    ");
            } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
                strcpy(usageDescr, "(Cont ID)");
            } else if (usage == kHIDUsage_Dig_ContactCount) {
                strcpy(usageDescr, "(ContCnt)");
            } else if (usage == kHIDUsage_Dig_TouchValid) {
                strcpy(usageDescr, "(IsValid)");
            } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
                strcpy(usageDescr, "(ScnTime)");
            } else if (usage == kHIDUsage_Dig_Width) {
                strcpy(usageDescr, "(Width)  ");
            } else if (usage == kHIDUsage_Dig_Height) {
                strcpy(usageDescr, "(Height) ");
            } else if (usage == kHIDUsage_Dig_Azimuth) {
                strcpy(usageDescr, "(Azimuth)");
            }
        }
        
        
        
        printf("[%ld]\t%#02lx\t%#02lx %s\t %8ld\n", (long)cookie, page, usage, usageDescr,  value);
    }
    printf("\n");
}


/**
 Dispatches touch data for the given collection, but only if all values needed were received
 */

void DispatchTouchDataForCollection(HIDDeviceState *device, IOHIDElementRef collection) {
    
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    CGFloat x = -1;
    CGFloat y = -1;
    
    CFIndex contactID = 0;
    CFIndex tipSwitch = 0;
    CFIndex isValid = 0;
    
    CFIndex width   = kCFNotFound;
    CFIndex height  = kCFNotFound;
    CFIndex azimuth = kCFNotFound;
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex value = ValueOfElement(device, element);
        
        if (value != kCFNotFound) {
            if (page == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_X) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)value;
                    x = ( (curr - min) / (max - min) ) + min;
                }
                
                else if (usage == kHIDUsage_GD_Y) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);
                    CGFloat curr = (CGFloat)value;
                    y = ( (curr - min) / (max - min) ) + min;
                }
            } //kHIDPage_GenericDesktop
            
            else if (page == kHIDPage_Digitizer) {
                if (usage == kHIDUsage_Dig_ContactIdentifier) {
                    contactID = value;
                } else if (usage == kHIDUsage_Dig_TipSwitch) {
                    tipSwitch = value;
                } else if (usage == kHIDUsage_Dig_TouchValid) {
                    isValid = value;
                } else if (usage == kHIDUsage_Dig_Width) {
                    width = value;
                } else if (usage == kHIDUsage_Dig_Height) {
                    height = value;
                } else if (usage == kHIDUsage_Dig_Azimuth) {
                    azimuth = value;
                }
            } // kHIDPage_Digitizer
        }
    }
    TouchInputManagerUpdateTouchPosition(gTouchManager, device->locationID, contactID, x, y, (int)tipSwitch, (int)isValid);
    
    //    if (width != kCFNotFound && height != kCFNotFound && azimuth != kCFNotFound) {
    //        TouchInputManagerUpdateTouchSize(gTouchManager, contactID, (CGFloat)width, (CGFloat)height, (CGFloat)azimuth);
    //    }
    
}



void DispatchTouches(HIDDeviceState *device) {
    
    CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
    CFIndex remainingUpdates = device->contactCount - device->hybridOffset;
    
    CFIndex numUpdates = numCollections;
    if (remainingUpdates < numCollections) {
        numUpdates = remainingUpdates;
    }
    
    CFIndex numElementsToPost = CFArrayGetCount(device->touchCollectionElements);
    if (numUpdates < numElementsToPost)
        numElementsToPost = numUpdates;
    
    // update the touch data
    for (CFIndex i=0; i<numElementsToPost; i++) {
        IOHIDElementRef collection = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, i);
        DispatchTouchDataForCollection(device, collection);
    }
    
    device->hybridOffset = device->hybridOffset + numUpdates;
    
    if (device->hybridOffset == device->contactCount) {
        device->hybridOffset = 0;
    }
    
    if (device->hybridOffset == 0) {
        TouchInputManagerDidProcessReport(gTouchManager, device->locationID);
    }
    
}



#pragma mark - Exclusive HID Usage (Seizing)

/*!
 Brings a device's exclusive-open state in line with gSeizeTouchDevices.
 Seizing routes the device's events to us alone (macOS stops receiving them); releasing returns it to shared use.
 Idempotent — only opens/closes when the state actually changes.
 */
static void ApplySeizeState(HIDDeviceState *state) {
    if (gSeizeTouchDevices && !state->seized) {
        IOReturn r = IOHIDDeviceOpen(state->device, kIOHIDOptionsTypeSeizeDevice);
        if (r == kIOReturnSuccess) {
            state->seized = true;
        } else {
            fprintf(stderr, "Failed to seize device 0x%08x (IOReturn 0x%08x)\n", state->locationID, r);
        }
    } else if (!gSeizeTouchDevices && state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }
}


/*!
 Opt-in exclusive access. When enabled, every accepted touch interface (current and future) is seized so macOS no longer receives its events.
 Separate pen interfaces stay shared. Pen reports on the selected touch interface (as on the M14t) are also seized.
 */
void SetTouchDevicesSeized(bool seize) {
    gSeizeTouchDevices = seize;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive) {
            ApplySeizeState(&gDevices[i]);
        }
    }
}



#pragma mark - Callbacks

/*!
 @param context void * pointer to your data, often a pointer to an object.
 @param result Completion result of desired operation.
 @param inSender Interface instance sending the completion routine.
 */

static void Handle_QueueValueAvailable(
    void * _Nullable        context,
    IOReturn                result,
    void * _Nullable        inSender
) {
    HIDDeviceState *device = DeviceStateForRef((IOHIDDeviceRef)context);
    if (!device || result != kIOReturnSuccess) return;

    uint64_t reportTimestamp = 0;
    Boolean hasValues = false;

    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            if (hasValues) DispatchTouches(device);
            break;
        }
        // A queue notification can contain several reports. Do not combine their
        // contact counts or overwrite the first half of a hybrid touch frame.
        uint64_t timestamp = IOHIDValueGetTimeStamp(valueRef);
        if (hasValues && timestamp != reportTimestamp) DispatchTouches(device);
        reportTimestamp = timestamp;
        hasValues = true;
        // process the HID value reference
        StoreInputValue(device, valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


/**
 Counts the logical collections that contain a ContactIdentifier, i.e. the number of
 simultaneous touch contacts this HID interface can report. This is how we tell the real
 multitouch surface (several contacts) apart from a sibling interface that only exposes a
 single-pointer or pen path (one or zero contacts) under the same locationID.
 */
static CFIndex CountContactCollections(IOHIDDeviceRef dev) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return 0;

    CFIndex contactCollections = 0;
    CFIndex count = CFArrayGetCount(elements);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IsContactCollection(el) && TouchscreenCollectionForElement(el)) contactCollections++;
    }
    CFRelease(elements);
    return contactCollections;
}



// Allocates device state and wires up the queue + input callbacks for an interface we've
// decided to treat as the active touchscreen. The callback context is the device ref so
// callbacks resolve to the right per-interface state even when locationIDs collide.
static HIDDeviceState* RegisterTouchDevice(IOHIDDeviceRef dev, uint32_t locationID, CFIndex contactCount) {
    HIDDeviceState *device = AllocateDeviceState(dev, locationID);
    if (!device) return NULL;
    device->contactCollectionCount = contactCount;

    void *context = (void *)dev;

    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    if (!elements) {
      fprintf(stderr, "Cannot read HID elements for 0x%08x. Check Input Monitoring permission.\n", locationID);
      DeallocateDeviceState(dev);
      return NULL;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
      IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
      if (IsContactCollection(element) && TouchscreenCollectionForElement(element)) {
        IdentifyElements(device, element, false);
        break;
      }
    }
    if (!device->areElementRefsSet) {
      CFRelease(elements);
      DeallocateDeviceState(dev);
      return NULL;
    }

    // Subscribe before the first report, including values that have not changed
    // (contact ID and tip/confidence flags can otherwise be missing indefinitely).
    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, dev, 1000, kIOHIDQueueOptionsTypeEnqueueAll);
    if (!queue) {
      fprintf(stderr, "Cannot create HID queue for 0x%08x. Check Input Monitoring permission.\n", locationID);
      CFRelease(elements);
      DeallocateDeviceState(dev);
      return NULL;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
      IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
      IOHIDElementType type = IOHIDElementGetType(element);
      if (type >= kIOHIDElementTypeInput_Misc && type <= kIOHIDElementTypeInput_ScanCodes &&
          TouchscreenCollectionForElement(element) == device->applicationCollectionElement) {
        IOHIDQueueAddElement(queue, element);
        // macOS may already have seen the first finger's fixed ID/confidence
        // before this queue existed. Seed unchanged fields from its cached input
        // values, without issuing a USB GET_REPORT request to the device.
        IOHIDValueRef value = NULL;
        IOReturn result = IOHIDDeviceGetValueWithOptions(dev, element, &value,
          kIOHIDDeviceGetValueWithoutUpdate);
        if (result == kIOReturnSuccess && value) StoreInputValue(device, value);
      }
    }
    CFRelease(elements);
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, context);
    device->queue = queue;
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDQueueStart(queue);

    ApplySeizeState(device);
    return device;
}


// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
    void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
    IOReturn        inResult,        // the result of the matching operation
    void *          inSender,        // the IOHIDManagerRef for the new device
    IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    printf("%s(context: %p, result: %d, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, inResult, inSender, (void*) inIOHIDDeviceRef);

    // read the location ID for this device
    CFNumberRef locationRef = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationRef) {
        CFNumberGetValue(locationRef, kCFNumberSInt32Type, &locationID);
    }

    printf("Touchscreen connected with locationID: 0x%08x\n", locationID);

    IOReturn openResult = IOHIDDeviceOpen(inIOHIDDeviceRef, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
      fprintf(stderr, "Cannot open touchscreen 0x%08x (IOReturn 0x%08x). Check Input Monitoring permission and restart Touch Up.\n",
        locationID, openResult);
      return;
    }

    // A combo digitizer exposes several interfaces under one locationID. Keep only the one
    // that actually carries multitouch: the interface with the most contact collections.
    CFIndex contactCount = CountContactCollections(inIOHIDDeviceRef);
    if (contactCount == 0) return;
    HIDDeviceState *existing = RegisteredDeviceForLocationID(locationID);

    if (existing == NULL) {
        if (RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount)) {
            TouchInputManagerDidConnectTouchscreen(gTouchManager, locationID);
        }
    } else if (contactCount > existing->contactCollectionCount) {
        // A better interface for an already-connected screen arrived (connect order is not
        // deterministic). Swap to it without bothering the upper layer — the locationID,
        // which is all the upper layer keys on, stays connected throughout.
        printf("Switching primary interface for 0x%08x: %ld -> %ld contact collections\n",
               locationID, existing->contactCollectionCount, contactCount);
        IOHIDDeviceRef oldDev = existing->device;
        DeallocateDeviceState(oldDev);
        if (!RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount)) {
          TouchInputManagerDidDisconnectTouchscreen(gTouchManager, locationID);
        }
    } else {
        printf("Ignoring secondary interface for 0x%08x (%ld <= %ld contact collections)\n",
               locationID, contactCount, existing->contactCollectionCount);
    }
}   // Handle_DeviceMatchingCallback



// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                                   void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                                   IOReturn       inResult,        // the result of the removing operation
                                   void *         inSender,        // the IOHIDManagerRef for the device being removed
                                   IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    printf("%s(context: %p, result: %d, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, inResult, inSender, (void*) inIOHIDDeviceRef);
    
    // Only the interface we actually registered as the touchscreen has state. Secondary
    // interfaces we ignored at match time have none, so their removal is a no-op and must
    // not tell the upper layer the screen went away while the primary is still present.
    HIDDeviceState *device = DeviceStateForRef(inIOHIDDeviceRef);
    if (!device) return;

    uint32_t locationID = device->locationID;
    printf("Touchscreen disconnected with locationID: 0x%08x\n", locationID);

    DeallocateDeviceState(inIOHIDDeviceRef);

    TouchInputManagerDidDisconnectTouchscreen(gTouchManager, locationID);
}   // Handle_RemovalCallback



#pragma mark - Start / Stop


// function to create matching dictionary
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) {
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
                                                              kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(
                                                         kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) {
                CFDictionarySetValue(result,
                                     CFSTR(kIOHIDDeviceUsagePageKey), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
                
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(
                                                                  kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) {
                        CFDictionarySetValue(result,
                                             CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } else {
                        fprintf(stderr, "%s: CFNumberCreate(usage) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } else {
                fprintf(stderr, "%s: CFNumberCreate(usage page) failed.", __PRETTY_FUNCTION__);
            }
        }
    } else {
        fprintf(stderr, "%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}   // CreateDeviceMatchingDictionary





void OpenHIDManager(void *delegate) {
    gTouchManager = delegate;
    
    
    gHidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    
    if (CFGetTypeID(gHidManager) != IOHIDManagerGetTypeID()) {
        printf("OH CRAP THIS IS NOT AN HID MANAGER");
    }
    
    
    //    CFMutableDictionaryRef keyboard =
    //    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Pen);
    //    CFMutableDictionaryRef keypad =
    //    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Touch);
    
    CFMutableDictionaryRef matchesList[] = {
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen),
    };
    
    
    
    CFArrayRef matches = CFArrayCreate(kCFAllocatorDefault,
                                       (const void **)matchesList, 1, NULL);
    IOHIDManagerSetDeviceMatchingMultiple(gHidManager, matches);
    CFRelease(matches);
    CFRelease(matchesList[0]);
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
    //    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);
    
    IOReturn result = IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
      fprintf(stderr, "Cannot open HID manager (IOReturn 0x%08x). Check Input Monitoring permission.\n", result);
    }
}



void CloseHIDManager(void) {
    if (!gHidManager) return;
    // clean up all active device states (DeallocateDeviceState releases any seize)
    while (gDeviceCount > 0) {
        DeallocateDeviceState(gDevices[0].device);
    }

    IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
    CFRelease(gHidManager);
    gHidManager = NULL;
}
