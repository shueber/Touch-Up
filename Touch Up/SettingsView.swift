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
    
  var permissionSettings: some View {
    Group {
      if !model.areRequiredPermissionsGranted {
        Text("Touch Up needs both permissions to turn touchscreen input into mouse events.")
      }

      permissionRow(
        title: "Input Monitoring",
        explanation: "Receives touches from USB touchscreens. A digitizer can be detected even when macOS blocks its touch reports.",
        isGranted: model.isInputMonitoringAccessGranted,
        requestAccess: model.grantInputMonitoringAccess
      )

      if !model.isInputMonitoringAccessGranted || model.isInputMonitoringRestartRequired {
        Text("After enabling Input Monitoring in System Settings, quit and reopen Touch Up to receive touches.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      permissionRow(
        title: "Accessibility",
        explanation: "Moves the pointer and sends clicks and gestures.",
        isGranted: model.isAccessibilityAccessGranted,
        requestAccess: model.grantAccessibilityAccess
      )
    }
  }

  private func permissionRow(
    title: String,
    explanation: String,
    isGranted: Bool,
    requestAccess: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Label(
          isGranted ? "Granted" : "Required",
          systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundColor(isGranted ? .green : .orange)
      }
      Text(explanation)
        .font(.caption)
        .foregroundColor(.secondary)
      if !isGranted {
        Button("Allow \(title)…", action: requestAccess)
          .buttonStyle(BorderedProminentButtonStyle())
      }
    }
  }
    
  var top: some View {
    Group {
      Toggle(model.uiLabels(for: \.isPublishingMouseEventsEnabled).title, isOn: $model.isPublishingMouseEventsEnabled)

      Toggle(isOn: $model.isMousePositionRestoredAfterTouch) {
        SettingsExplanationLabel(labels: model.uiLabels(for: \.isMousePositionRestoredAfterTouch))
      }
    }
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
    
    
    var parameterSettings: some View {
        Group {
          HStack {
            Slider(value: $model.tapMovementTolerance, in: 0.5...5, step: 0.5) {
              SettingsExplanationLabel(labels: model.uiLabels(for: \.tapMovementTolerance))
            }
            Text("\(model.tapMovementTolerance, specifier: "%.1f") mm")
              .monospacedDigit()
              .foregroundColor(.secondary)
          }

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
            
            Toggle(isOn: $model.ignoreOriginTouches) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.ignoreOriginTouches))
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
                Section("Permissions") {
                    permissionSettings
                }
                
                Section {
                    top
                }

                Section("Touchscreens") {
                    DigitizerMappingView(model: self.model)
                }

                Section("Gestures") {
                    gestureSettings
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
                LegacySection(title: "Permissions") {
                    permissionSettings
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
