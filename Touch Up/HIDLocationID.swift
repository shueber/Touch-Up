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
    
    var properties: RawProperties? {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = findProperties(in: service, matchingLocationID: self) {
                IOObjectRelease(service)
                return props
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return nil
    }

    private func findProperties(in entry: io_registry_entry_t, matchingLocationID: HIDLocationID) -> RawProperties? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = props?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // USB device nodes use lowercase "locationID"; HID nodes use kIOHIDLocationIDKey ("LocationID")
        let entryLocationID = properties["locationID"] as? UInt32
            ?? properties[kIOHIDLocationIDKey] as? UInt32

        guard entryLocationID == matchingLocationID else { return nil }

        // NOTE: We intentionally do NOT descend into child nodes. A device's interface
        // and HID nubs inherit the same locationID but carry none of the vendor/product
        // strings, so recursing and returning the first locationID hit would yield an
        // all-nil result. `IOServiceGetMatchingServices(kIOUSBDeviceClassName, …)` already
        // returns every USB device flatly — including ones behind hubs — so matching the
        // device node directly is both sufficient and unambiguous.
        return RawProperties(
            name:         properties["USB Product Name"] as? String ?? properties[kIOHIDProductKey] as? String,
            vendorID:     (properties[kUSBVendorID] as? UInt32).map { UInt16($0) },
            productID:    (properties[kUSBProductID] as? UInt32).map { UInt16($0) },
            bcdDevice:    (properties["bcdDevice"] as? UInt32).map { UInt16($0) },
            serialNumber: properties[kUSBSerialNumberString] as? String ?? properties[kIOHIDSerialNumberKey] as? String
        )
    }
    
    struct RawProperties {
        let name: String?
        let vendorID: UInt16?
        let productID: UInt16?
        let bcdDevice: UInt16?
        let serialNumber: String?
    }
}
