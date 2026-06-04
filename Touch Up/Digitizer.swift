//
//  Digitizer.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//

import Foundation
import CoreGraphics

/// Per-digitizer settings, keyed by `HIDLocationID` and persisted to `UserDefaults`.
///
/// Only the screen identity (`screenID` + `screenUUID`) and `additionalRotation` are stored.
/// The actually resolved `TUCScreen` is *not* kept here: the screen list is rebuilt from
/// scratch on every display reconfiguration, so any held reference would go stale. The screen
/// is therefore resolved lazily from this identity (see `TouchUp.resolvedMapping(forLocationID:)`).
struct DigitizerConfig: Codable, Hashable {
    /// `CGDirectDisplayID` — effectively the index in the screen arrangement. Weaker match.
    var screenID: UInt?
    /// Stable per physical panel across launches/rearrangements. Stronger match.
    var screenUUID: String?
    var additionalRotation: CGFloat = 0
}

/// How confidently a digitizer's stored screen identity could be resolved against the
/// currently connected screens. Transient (computed on every resolution), never persisted.
/// Intended purely as a UI hint to flag potentially wrong mappings.
enum ScreenMatch {
    case exact       // UUID hit — safe
    case idFallback  // only the display ID matched; UUID gone/changed (e.g. after a rearrange)
    case implicit    // no stored match; fell back to the most recently added screen
    case unmapped    // no screen could be resolved at all
}

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
    
    var deviceName: String {
        self.name ?? "Touch Digitizer"
    }
    
    var locationIDString: String {
        "0x\(String(format: "%08x", locationID))"
    }

    var isUniquelyIdentifiable: Bool {
        serialNumber != nil
    }
    
    var id: HIDLocationID {
        locationID
    }
}
