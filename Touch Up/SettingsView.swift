//
//  SettingsView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

struct SettingsView: View {
    
    @ObservedObject var model: TouchUp
    
    var welcomeBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Touch Up 🐑")
                    .font(.largeTitle)
                Text("Touch Up converts USB HID data from any Windows certified touchscreen to mouse events.\nInjecting mouse events requires access to accessibility APIs. You can allow this by clicking the button below.")
            }
            
            HStack {
                Spacer()
                Button {
                    model.grantAccessibilityAccess()
                } label: {
                    
                    Text("Grant Accessibility Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }
    
    var inputMonitoringBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input Monitoring Required")
                    .font(.headline)
                Text("macOS requires Input Monitoring permission to read the touchscreen. Click Grant Access, enable Touch Up in the list that opens, then relaunch the app.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button {
                    model.requestInputMonitoringAccess()
                } label: {
                    Text("Grant Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }

    var top: some View {
        Toggle(model.uiLabels(for: \.isPublishingMouseEventsEnabled).title, isOn: $model.isPublishingMouseEventsEnabled)
    }

    
    var gestureSettings: some View {
        Group {
            
            let mode_ = Binding {
                model.isClickOnLiftEnabled ? 2 : (model.isScrollingWithOneFingerEnabled ? 0 : 1)
            } set: { value in
                model.isScrollingWithOneFingerEnabled = value == 0
                model.isClickOnLiftEnabled = value == 2
            }
            
            Picker(selection: mode_) {
                Text("Scroll").tag(0)
                Text("Move Cursor").tag(1)
                Text("Point and Click").tag(2)
            } label: {
                SettingsExplanationLabel(labels: ("On Finger Drag", "Specify which action should occur when dragging one finger on the touch screen."))
            }

            
            Toggle(isOn: $model.isSecondaryClickEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isSecondaryClickEnabled))
            }
            
            Toggle(isOn: $model.isMagnificationEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isMagnificationEnabled))
            }
            
            Toggle(isOn: $model.isClickWindowToFrontEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isClickWindowToFrontEnabled))
            }
        }
    }
    
    
    var multiFingerShortcutSettings: some View {
        Group {
            ForEach(MultiFingerGesture.threeFingerCases) { gesture in
                gesturePicker(for: gesture)
            }
            ForEach(MultiFingerGesture.fourFingerCases) { gesture in
                gesturePicker(for: gesture)
            }
        }
    }

    private func gesturePicker(for gesture: MultiFingerGesture) -> some View {
        let selection = Binding<String?> {
            model.gestureShortcutMappings[gesture.rawValue]
        } set: { newValue in
            if let newValue {
                model.gestureShortcutMappings[gesture.rawValue] = newValue
            } else {
                model.gestureShortcutMappings.removeValue(forKey: gesture.rawValue)
            }
        }

        return Picker(selection: selection) {
            Text("Off").tag(String?.none)
            ForEach(ShortcutPreset.catalog) { preset in
                Text("\(preset.display)   \(preset.name)")
                    .tag(Optional(preset.id))
            }
        } label: {
            Text(gesture.title)
        }
    }


    var parameterSettings: some View {
        Group {
            Slider(value: $model.holdDuration, in: 0.0...0.16, step: 0.02){
                SettingsExplanationLabel(labels: model.uiLabels(for: \.holdDuration))
            }
            
            Slider(value: $model.doubleClickDistance, in: 0...8, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.doubleClickDistance))
            }
        }
    }
    
    
    var troubleshootingSettings: some View {
        Group {
            let errorResistance_ = Binding {Double(model.errorResistance)} set: {
                model.errorResistance = NSInteger(Int($0)) }
            
            Slider(value: errorResistance_ , in: 0...10, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.errorResistance))
            }
            
            Slider(value: $model.stationaryThreshold, in: 0...2, step: 0.1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.stationaryThreshold))
            }
            
            Slider(value: $model.edgeDeadZone, in: 0...30, step: 5) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.edgeDeadZone))
            }

            Toggle(isOn: $model.ignoreOriginTouches) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.ignoreOriginTouches))
            }

            Toggle(isOn: $model.isExclusiveAccessEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isExclusiveAccessEnabled))
            }

            Toggle(isOn: $model.areAdditionalDigitizerRotationSettingsVisible) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.areAdditionalDigitizerRotationSettingsVisible))
            }
        }
    }
    
    
    var footer: some View {
        HStack {
            Spacer()
            VStack {
                if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Touch Up v\(versionString)")
                        .font(.title2)
                }

                Text("Made with 🐑 in Aachen")
                    .font(.footnote)
                
                Link(destination: URL(string: "https://github.com/shueber/Touch-Up")!, label: {
                    Label("GitHub", systemImage: "link")
                        .foregroundColor(.accentColor)
                })
            }
            .padding(.vertical)
            Spacer()
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        
    }
    
    var container: some View {
        if #available(macOS 13.0, *) {
            return Form {
                if !model.isAccessibilityAccessGranted {
                    Section {
                        welcomeBanner
                    } footer: {
                        Rectangle()
                            .frame(width:0, height:0)
                            .foregroundColor(.clear)
                    }

                }

                if !model.isInputMonitoringGranted {
                    Section {
                        inputMonitoringBanner
                    }
                }

                Section {
                    top
                    Toggle(isOn: $model.isTouchIndicatorEnabled) {
                        SettingsExplanationLabel(labels: model.uiLabels(for: \.isTouchIndicatorEnabled))
                    }
                }

                Section("Touchscreens") {
                    DigitizerMappingView(model: self.model)
                }

                Section("Gestures") {
                    gestureSettings
                }

                Section {
                    multiFingerShortcutSettings
                } header: {
                    Text("Multi-Finger Shortcuts")
                } footer: {
                    Text("A swipe fires its shortcut once the fingers travel far enough; a quick lift without moving counts as a tap; holding still turns into a long-press that keeps the mapped key pressed until the fingers lift. While the fingers are down, mouse input is suppressed. Set a group to \"Off\" to keep the default cursor behavior for that finger count.")
                }

                Section("Parameters") {
                    parameterSettings
                }

                Section {
                    troubleshootingSettings
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    footer
                }



            }
            .formStyle(.grouped)

        } else {
            return List {
                if !model.isAccessibilityAccessGranted {
                    LegacySection {
                        welcomeBanner
                    }
                }

                if !model.isInputMonitoringGranted {
                    LegacySection {
                        inputMonitoringBanner
                    }
                }

                LegacySection {
                    top
                }

                LegacySection(title: "Touchscreens") {
                    DigitizerMappingView(model: self.model)
                }

                LegacySection(title: "Gestures") {
                    gestureSettings
                }

                LegacySection(title: "Multi-Finger Shortcuts") {
                    multiFingerShortcutSettings
                }

                LegacySection(title: "Parameters") {
                    parameterSettings
                }
                
                LegacySection(title: "Troubleshooting") {
                    troubleshootingSettings
                }
                
                footer
                
            }
            .toggleStyle(.switch)
            
        }
    }
    
    
    
    var body: some View {
        container
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 350,  maxHeight: .infinity)
        
    }
}


struct LegacySection<Content: View>: View {
    var title: String? = nil
    var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading) {
            if let title = title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor(.secondary.opacity(0.1))
                    .shadow(radius: 1)
                    
                    
                
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(12)
            }
            
        }
        .padding(.bottom)
    }
}


struct SettingsExplanationLabel: View {
    
    let labels: (title:String, description:String)
    
    var body: some View {
        VStack(alignment:.leading, spacing: 4) {
            Text(labels.title)
            Text(labels.description)
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}



struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(model: TouchUp())
    }
}
