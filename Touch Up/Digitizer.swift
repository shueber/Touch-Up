//
//  Digitizer.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//

import Foundation

struct Digitizer: Codable, Hashable, Identifiable {

    let locationID: HIDLocationID
    let name: String?
    let vendorID: UInt16?
    let productID: UInt16?
    let bcdDevice: UInt16?
    let serialNumber: String?

    init(locationID: HIDLocationID) {
        let properties = locationID.properties
        self.locationID = locationID
        self.name = properties?.name
        self.vendorID = properties?.vendorID
        self.productID = properties?.productID
        self.bcdDevice = properties?.bcdDevice
        self.serialNumber = properties?.serialNumber
    }

    var displayName: String {
        let name = self.name ?? "Touch Digitizer"
        return "\(name) (0x\(String(format: "%08x", locationID)))"
    }

    var isUniquelyIdentifiable: Bool {
        serialNumber != nil
    }
    
    var id: HIDLocationID {
        locationID
    }
}
