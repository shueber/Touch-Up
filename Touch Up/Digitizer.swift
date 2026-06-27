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
/// Screen identity, rotation, and optional coordinate calibration are stored.
/// The actually resolved `TUCScreen` is *not* kept here: the screen list is rebuilt from
/// scratch on every display reconfiguration, so any held reference would go stale. The screen
/// is therefore resolved lazily from this identity (see `TouchUp.resolvedMapping(forLocationID:)`).
struct DigitizerConfig: Codable, Hashable {
    /// `CGDirectDisplayID` — effectively the index in the screen arrangement. Weaker match.
    var screenID: UInt?
    /// Stable per physical panel across launches/rearrangements. Stronger match.
    var screenUUID: String?
    var additionalRotation: CGFloat = 0
    var calibration: TouchCalibration?
}

struct TouchCalibration: Codable, Hashable {
    var a: CGFloat
    var b: CGFloat
    var c: CGFloat
    var d: CGFloat
    var e: CGFloat
    var f: CGFloat
    var meanError: CGFloat
    var maxError: CGFloat

    func apply(to point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, a * point.x + b * point.y + c)),
            y: min(1, max(0, d * point.x + e * point.y + f))
        )
    }

    static func fit(samples: [(target: CGPoint, observed: CGPoint)]) -> TouchCalibration? {
        guard samples.count >= 3 else { return nil }

        var ata = Array(repeating: Array(repeating: CGFloat(0), count: 3), count: 3)
        var bx = Array(repeating: CGFloat(0), count: 3)
        var by = Array(repeating: CGFloat(0), count: 3)

        for sample in samples {
            let row = [sample.observed.x, sample.observed.y, CGFloat(1)]
            for i in 0..<3 {
                bx[i] += row[i] * sample.target.x
                by[i] += row[i] * sample.target.y
                for j in 0..<3 {
                    ata[i][j] += row[i] * row[j]
                }
            }
        }

        guard let x = solve3x3(ata, bx), let y = solve3x3(ata, by) else {
            return nil
        }

        var errors = [CGFloat]()
        let calibration = TouchCalibration(
            a: x[0], b: x[1], c: x[2],
            d: y[0], e: y[1], f: y[2],
            meanError: 0, maxError: 0
        )

        for sample in samples {
            let corrected = calibration.apply(to: sample.observed)
            errors.append(hypot(corrected.x - sample.target.x, corrected.y - sample.target.y))
        }

        return TouchCalibration(
            a: x[0], b: x[1], c: x[2],
            d: y[0], e: y[1], f: y[2],
            meanError: errors.reduce(0, +) / CGFloat(errors.count),
            maxError: errors.max() ?? 0
        )
    }

    private static func solve3x3(_ matrix: [[CGFloat]], _ vector: [CGFloat]) -> [CGFloat]? {
        var a = matrix
        var b = vector

        for column in 0..<3 {
            var pivot = column
            for row in column..<3 where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 0.000001 else { return nil }

            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }

            let divisor = a[column][column]
            for j in column..<3 {
                a[column][j] /= divisor
            }
            b[column] /= divisor

            for row in 0..<3 where row != column {
                let factor = a[row][column]
                for j in column..<3 {
                    a[row][j] -= factor * a[column][j]
                }
                b[row] -= factor * b[column]
            }
        }

        return b
    }
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
