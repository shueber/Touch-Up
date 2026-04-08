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
    uint32_t                locationID;
    Boolean                 isActive;
    
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


#pragma mark - Device State Management


HIDDeviceState* DeviceStateForLocationID(uint32_t locationID) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].locationID == locationID) {
            return &gDevices[i];
        }
    }
    return NULL;
}


HIDDeviceState* AllocateDeviceState(uint32_t locationID) {
    if (gDeviceCount >= kMaxTouchscreens) {
        fprintf(stderr, "Maximum number of touchscreens (%d) reached.\n", kMaxTouchscreens);
        return NULL;
    }
    
    HIDDeviceState *state = &gDevices[gDeviceCount];
    memset(state, 0, sizeof(HIDDeviceState));
    
    state->locationID = locationID;
    state->isActive = TRUE;
    state->contactCount = 1;
    state->touchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->contactIdentifiers = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->storedInputValues = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    
    gDeviceCount++;
    return state;
}


void DeallocateDeviceState(uint32_t locationID) {
    int index = -1;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].locationID == locationID) {
            index = i;
            break;
        }
    }
    if (index < 0) return;
    
    HIDDeviceState *state = &gDevices[index];
    
    if (state->queue) {
        IOHIDQueueStop(state->queue);
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


int64_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(HIDDeviceState *device, IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    int64_t hash = StorageKeyForElement(element);
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
    
    CFIndex keyValue = StorageKeyForElement(elem);
    
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




/**
 We need to inspect the HID tree as a whole once to see which elements are grouped into logical groups of touch data.
 Just pass in any element of the tree, the function will walk up the tree, search for the logical groups and rememeber them in the global variables.
 */
void IdentifyElements(HIDDeviceState *device, IOHIDElementRef anyElement, Boolean printTree) {
    
    IOHIDElementRef applicationCollection = anyElement;
    IOHIDElementType type = kIOHIDElementTypeOutput;
    
    while (type != kIOHIDElementCollectionTypeApplication) {
        IOHIDElementRef next = IOHIDElementGetParent(applicationCollection);
        if (next) {
            applicationCollection = next;
            type = IOHIDElementGetType(applicationCollection);
        } else {
            break;
        }
    }
    
    device->applicationCollectionElement = applicationCollection;
    
    
    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = CFArrayGetCount(children);
    
    if (printTree) {
        printf("# parent (type %u) has %ld children:\n", type, numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        IOHIDElementType type =  IOHIDElementGetType(element);
        IOHIDElementCollectionType collectionType = IOHIDElementGetCollectionType(element);
        
        if (type == kIOHIDElementTypeCollection && collectionType == kIOHIDElementCollectionTypeLogical) {
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
        
        
        
        printf("[%u]\t%#02lx\t%#02lx %s\t %8ld\n", cookie, page, usage, usageDescr,  value);
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
    uint32_t locationID = (uint32_t)(uintptr_t)context;
    HIDDeviceState *device = DeviceStateForLocationID(locationID);
    if (!device) return;
    
    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            // finished processing 1 report
            DispatchTouches(device);
            break;
        }
        // process the HID value reference
        StoreInputValue(device, valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


static void Handle_InputValueCallback (
    void *          inContext,      // context from IOHIDManagerRegisterInputValueCallback
    IOReturn        inResult,       // completion result for the input value operation
    void *          inSender,       // the IOHIDManagerRef
    IOHIDValueRef   inIOHIDValueRef // the new element value
) {
    uint32_t locationID = (uint32_t)(uintptr_t)inContext;
    HIDDeviceState *device = DeviceStateForLocationID(locationID);
    if (!device) return;
    
    if(!device->areElementRefsSet) {
        IOHIDElementRef e = IOHIDValueGetElement(inIOHIDValueRef);
        IdentifyElements(device, e, TRUE);
        device->areElementRefsSet = TRUE;
    }
    
    IOHIDElementRef elem = IOHIDValueGetElement(inIOHIDValueRef);
    
    Boolean added = IOHIDQueueContainsElement(device->queue, elem);
    if(!added) {
        IOHIDQueueAddElement(device->queue, elem);
        StoreInputValue(device, inIOHIDValueRef);
    }
    
}








// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
    void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
    IOReturn        inResult,        // the result of the matching operation
    void *          inSender,        // the IOHIDManagerRef for the new device
    IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    printf("%s(context: %p, result: %p, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, (void *) inResult, inSender, (void*) inIOHIDDeviceRef);
    
    // read the location ID for this device
    CFNumberRef locationRef = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationRef) {
        CFNumberGetValue(locationRef, kCFNumberSInt32Type, &locationID);
    }
    
    printf("Touchscreen connected with locationID: 0x%08x\n", locationID);
    
    HIDDeviceState *device = AllocateDeviceState(locationID);
    if (!device) return;
    
    void *locationContext = (void *)(uintptr_t)locationID;
    
    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, inIOHIDDeviceRef, 1000, kNilOptions);
    
    if (CFGetTypeID(queue) != IOHIDQueueGetTypeID()) {
        // this is not a valid HID queue reference!
    }
    
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, locationContext);
    IOHIDQueueStart(queue);
    device->queue = queue;
    
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);
    
    // register per-device input value callback
    IOHIDDeviceRegisterInputValueCallback(inIOHIDDeviceRef, Handle_InputValueCallback, locationContext);
    
    TouchInputManagerDidConnectTouchscreen(gTouchManager, locationID);
    
}   // Handle_DeviceMatchingCallback



// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                                   void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                                   IOReturn       inResult,        // the result of the removing operation
                                   void *         inSender,        // the IOHIDManagerRef for the device being removed
                                   IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    printf("%s(context: %p, result: %p, sender: %p, device: %p).\n",
           __PRETTY_FUNCTION__, inContext, (void *) inResult, inSender, (void*) inIOHIDDeviceRef);
    
    CFNumberRef locationRef = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationRef) {
        CFNumberGetValue(locationRef, kCFNumberSInt32Type, &locationID);
    }
    
    printf("Touchscreen disconnected with locationID: 0x%08x\n", locationID);
    
    DeallocateDeviceState(locationID);
    
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
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
    //    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);
    
    IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
}



void CloseHIDManager(void) {
    // clean up all active device states
    while (gDeviceCount > 0) {
        DeallocateDeviceState(gDevices[0].locationID);
    }
    
    IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
}

