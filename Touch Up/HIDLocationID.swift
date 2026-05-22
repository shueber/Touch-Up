//
//  HIDLocationID.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//

import Foundation
import IOKit
import IOKit.usb

typealias HIDLocationID = UInt32

extension HIDLocationID {
    var usbDeviceName: String {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return "Touch Digitizer (0x\(String(format: "%08x", self)))"
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let name = findUSBProductName(in: service, matchingLocationID: self) {
                IOObjectRelease(service)
                return name
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return "Touch Digitizer (0x\(String(format: "%08x", self)))"
    }

    private func findUSBProductName(in entry: io_registry_entry_t, matchingLocationID: UInt32) -> String? {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let properties = props?.takeRetainedValue() as? [String: Any] {

            // USB device nodes use lowercase "locationID"; HID nodes use kIOHIDLocationIDKey ("LocationID")
            let entryLocationID = properties["locationID"] as? UInt32
                ?? properties[kIOHIDLocationIDKey] as? UInt32

            if entryLocationID == matchingLocationID {
                return properties["USB Product Name"] as? String
                    ?? properties[kIOHIDProductKey] as? String
            }
        }

        // Recurse into children to find devices behind USB hubs
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        var child = IOIteratorNext(childIterator)
        while child != 0 {
            if let name = findUSBProductName(in: child, matchingLocationID: matchingLocationID) {
                IOObjectRelease(child)
                return name
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIterator)
        }

        return nil
    }
}
