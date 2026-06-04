//
//  DigitizerMappingView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 04.06.26.
//

import SwiftUI

struct DigitizerMappingView: View {
    
    @ObservedObject var model: TouchUp
    
    var body: some View {
        if model.connectedDigitizers.isEmpty {
            noDigitizersPlaceholder
        } else {
            ForEach(model.connectedDigitizers) { digitizer in
                digitizerControls(for: digitizer)
            }
        }
    }
    
    
    var noDigitizersPlaceholder: some View {
        VStack(alignment: .center) {
            Image(systemName: "rectangle.slash")
                .font(.largeTitle)
            Text("Upon connecting a touchscreen, it will appear here.")
                .font(.caption)
                
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
    }
    
    
    @ViewBuilder
    private func digitizerControls(for digitizer: Digitizer) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 4) {
                Text(digitizer.locationIDString)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    let screen = model.resolvedMapping(forLocationID: digitizer.locationID).screen
                    (NSApp.delegate as? AppDelegate)?.showDebugOverlay(on: screen, digitizer: digitizer.locationID)
                }, label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Test")
                    }
                    .font(.caption)
                })
                .foregroundColor(.accentColor)
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                let current = model.digitizerConfigs[digitizer.locationID]?.additionalRotation ?? 0

                Text(digitizer.deviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.areAdditionalDigitizerRotationSettingsVisible || current != 0 {
                    rotationPicker(for: digitizer)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrowshape.forward.fill")
                    .foregroundColor(.secondary)

                Spacer(minLength: 8)

                screenPicker(for: digitizer)
            }
        }
    }

    @ViewBuilder
    private func screenPicker(for digitizer: Digitizer) -> some View {
        let selection = Binding {
            model.resolvedMapping(forLocationID: digitizer.locationID).screen?.uuid ?? ""
        } set: { uuid in
            model.assignScreen(model.connectedScreens.first { $0.uuid == uuid }, toDigitizer: digitizer.locationID)
        }

        Picker(selection: selection) {
            ForEach(model.connectedScreens) { screen in
                Text(screen.name).tag(screen.uuid)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }


    @ViewBuilder
    private func rotationPicker(for digitizer: Digitizer) -> some View {
        let selection = Binding {
            model.digitizerConfigs[digitizer.locationID]?.additionalRotation ?? 0
        } set: { rotation in
            model.setRotation(rotation, forDigitizer: digitizer.locationID)
        }

        Picker(selection: selection) {
            let rotations: [CGFloat] = [0, 90, 180, 270]
            ForEach(rotations, id: \.self) {
                Text("\(Int($0))°").tag($0)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

}

#Preview {
    DigitizerMappingView(model: TouchUp())
}
