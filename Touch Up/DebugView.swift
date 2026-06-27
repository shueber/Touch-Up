//
//  DebugView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 11.02.23.
//

import SwiftUI
import AppKit
import TouchUpCore

struct DebugView: View {
    
    @ObservedObject var model: TouchUp
    
    let locationID: HIDLocationID?
    
    let closeAction: ()->Void
    
    var pixelsPerMM: CGFloat

    @State private var calibrationSamples = [(target: CGPoint, observed: CGPoint)]()
    @State private var currentCalibrationIndex = 0
    @State private var processedCalibrationTouches = Set<String>()
    @State private var isCalibrating = false
    @State private var calibrationMessage: String?

    private let calibrationTargets = [
        CGPoint(x: 0.1, y: 0.1),
        CGPoint(x: 0.9, y: 0.1),
        CGPoint(x: 0.9, y: 0.9),
        CGPoint(x: 0.1, y: 0.9),
        CGPoint(x: 0.5, y: 0.5)
    ]
    
    init(model: TouchUp, locationID: HIDLocationID?, closeAction: @escaping ()->Void) {
        self.model = model
        self.locationID = locationID
        if let locationID, let screen = model.touchscreen(forLocationID: locationID) {
            self.pixelsPerMM = screen.pixelsPerMM()
        } else {
            self.pixelsPerMM = 30
        }
        self.closeAction = closeAction
    }
    
    func colorForPhase(_ phase: NSTouch.Phase) -> Color {
        switch phase {
        case .stationary:
            return Color.yellow
            
        case .began:
            return Color.blue
            
        case .ended:
            return Color.red
            
        case .cancelled:
            return Color.orange
            
        default:
            return Color.green
        }
    }
    
    var allTouches: [TUCTouch] {
        if let locationID = locationID {
            return model.touches.filter {$0.locationID == locationID}
        } else {
            return model.touches
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            
            Rectangle()
                .foregroundColor(Color(white: 0.1))
                .frame(maxWidth:.infinity, maxHeight: .infinity)
                .overlay(GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        calibrationTarget(in: geo.size)

                        ForEach(allTouches, id:\.uuid) { point in
                            Circle()
                                .foregroundColor(colorForPhase(point.phase))
                                .border(Color.gray, width: point.confidenceFlag ? 5: 0)
                                .opacity(point.isActive() ? 1 : 0.5)
                                .frame(width: 16 * pixelsPerMM, height: 16 * pixelsPerMM)
                                .position(x: geo.size.width * point.location.x,
                                          y: geo.size.height * point.location.y)
                            
                            
                            Text("\(point.contactID)")
                                .font(.system(size: 40))
                                .position(x: geo.size.width * point.location.x,
                                          y: geo.size.height * point.location.y)
                            
                        }
                    }
                })
            
            
            VStack(spacing: 16) {
                calibrationControls

                Button(action: {
                    closeAction()
                }, label: {
                    HStack {
                        Text("Close overlay with ")
                        Label("W", systemImage: "command.square.fill")
                        Text("or by mouse-clicking here")
                    }
                    .font(.largeTitle)
                    .modify {
                        if #available(macOS 13.0, *) {
                            $0.fontDesign(.rounded)
                        } else { $0 }
                    }
                })
                .foregroundColor(.gray)
                .buttonStyle(.borderless)
                .keyboardShortcut(KeyEquivalent("w"), modifiers: [.command])
            }
            .padding(.bottom, 120)
        }
        .onReceive(model.$touches) { touches in
            processCalibrationTouches(touches)
        }
        
    }

    @ViewBuilder
    private func calibrationTarget(in size: CGSize) -> some View {
        if isCalibrating && currentCalibrationIndex < calibrationTargets.count {
            let target = calibrationTargets[currentCalibrationIndex]
            let x = target.x * size.width
            let y = target.y * size.height

            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 72, height: 72)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 96, height: 3)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: 96)
            }
            .position(x: x, y: y)
        }
    }

    @ViewBuilder
    private var calibrationControls: some View {
        if let locationID = locationID {
            VStack(spacing: 10) {
                if isCalibrating {
                    Text("Calibration \(currentCalibrationIndex + 1) of \(calibrationTargets.count)")
                        .font(.title2)
                    Button("Cancel Calibration") {
                        stopCalibration()
                    }
                } else {
                    if let message = calibrationMessage {
                        Text(message)
                            .font(.headline)
                    } else if let calibration = model.digitizerConfigs[locationID]?.calibration {
                        Text(String(format: "Calibrated: mean %.1f pt, max %.1f pt",
                                    calibration.meanError * calibrationErrorScale,
                                    calibration.maxError * calibrationErrorScale))
                            .font(.headline)
                    } else {
                        Text("Not calibrated")
                            .font(.headline)
                    }

                    HStack(spacing: 16) {
                        Button("Start Calibration") {
                            startCalibration(for: locationID)
                        }
                        Button("Reset Calibration") {
                            model.setCalibration(nil, forDigitizer: locationID)
                            calibrationMessage = "Calibration reset"
                        }
                    }
                }
            }
            .foregroundColor(.white)
            .padding(14)
            .background(Color.black.opacity(0.55))
            .cornerRadius(8)
        }
    }

    private func startCalibration(for locationID: HIDLocationID) {
        calibrationSamples.removeAll()
        processedCalibrationTouches.removeAll()
        currentCalibrationIndex = 0
        calibrationMessage = nil
        isCalibrating = true
        model.calibrationBypassLocationID = locationID
    }

    private func stopCalibration() {
        isCalibrating = false
        model.calibrationBypassLocationID = nil
    }

    private func processCalibrationTouches(_ touches: [TUCTouch]) {
        guard isCalibrating,
              let locationID = locationID,
              currentCalibrationIndex < calibrationTargets.count
        else { return }

        guard let touch = touches.first(where: {
            $0.locationID == locationID &&
            $0.phase == .ended &&
            !processedCalibrationTouches.contains($0.uuid.uuidString)
        }) else { return }

        processedCalibrationTouches.insert(touch.uuid.uuidString)
        calibrationSamples.append((
            target: calibrationTargets[currentCalibrationIndex],
            observed: touch.location
        ))
        currentCalibrationIndex += 1

        if currentCalibrationIndex == calibrationTargets.count {
            finishCalibration(for: locationID)
        }
    }

    private func finishCalibration(for locationID: HIDLocationID) {
        model.calibrationBypassLocationID = nil
        isCalibrating = false

        guard let calibration = TouchCalibration.fit(samples: calibrationSamples) else {
            calibrationMessage = "Calibration failed"
            return
        }

        model.setCalibration(calibration, forDigitizer: locationID)
        calibrationMessage = String(format: "Calibration saved: mean %.1f pt, max %.1f pt",
                                    calibration.meanError * calibrationErrorScale,
                                    calibration.maxError * calibrationErrorScale)
    }

    private var calibrationErrorScale: CGFloat {
        guard let locationID,
              let screen = model.touchscreen(forLocationID: locationID)
        else { return 1 }
        return max(screen.frame.size.width, screen.frame.size.height)
    }
}

struct DebugView_Previews: PreviewProvider {
    static var previews: some View {
        DebugView(model: TouchUp(), locationID: nil, closeAction: {})
    }
}


extension View {
    func modify<T: View>(@ViewBuilder _ modifier: (Self) -> T) -> some View {
        return modifier(self)
    }
}
