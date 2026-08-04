//
//  Model.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
import TouchUpCore

class TouchUp: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    @Published var isPublishingMouseEventsEnabled = true
    
    @Published var connectionState: ConnectionState = .disconnected
    
    @Published var holdDuration: TimeInterval = 0.1
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var tapDistance: CGFloat = 2.5 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    @Published var isScrollingWithOneFingerEnabled = false
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isClickWindowToFrontEnabled = false
    @Published var isClickOnLiftEnabled = false
    @Published var isPressAndHoldEnabled = false

    @Published var areAdditionalDigitizerRotationSettingsVisible = false


    @Published var connectedScreens = [TUCScreen]()
    @Published var connectedDigitizers = [Digitizer]()

    /// Live config for every currently connected digitizer, keyed by `HIDLocationID`.
    /// Source of truth for the UI and for the delegate resolution.
    @Published var digitizerConfigs: [HIDLocationID: DigitizerConfig] = [:]

    /// All configs ever persisted (also for digitizers that are currently disconnected),
    /// keyed by `HIDLocationID`. Loaded once at launch, re-saved on every `persistMapping`.
    private var persistedConfigs: [HIDLocationID: DigitizerConfig] = [:]

    /// `CGDirectDisplayID` of the screen that connected most recently. Used as the implicit
    /// fallback target when a digitizer has no (matching) stored screen identity.
    var idOfLastAddedScreen: UInt?


    @Published var isAccessibilityAccessGranted = false


    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens()

        // a new screen appeared — remember it as the implicit fallback target.
        if connectedScreens.count > oldScreenList.count {
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.idOfLastAddedScreen = new.id
            }
        }

        // The screen list was rebuilt, so any resolved mapping may have shifted.
        updateConnectionState()
    }

    
    func checkAccessibilityAccessGranted() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        self.isAccessibilityAccessGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: true] as CFDictionary?)
    }
    
    func grantAccessibilityAccess() {
        self.touchManager.triggerSystemAccessibilityAccessAlert()
        (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        self.isAccessibilityAccessGranted = true
    }
    
    
    override init() {
        self.touchManager = TUCTouchInputManager()

        super.init()

        self.loadDigitizerConfigs()
        self.screenParametersDidChange()
        
        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchUp.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        initPreferences()
        
        checkAccessibilityAccessGranted()
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}


// MARK: - Loading, Saving and Syncing Settings with Framework
extension TouchUp {
    
    func initPreferences() {
        let defaults = UserDefaults.standard
        
        defaults.register(defaults: [
            "holdDuration" : 0.1,
            "doubleClickDistance" : 8,
            "tapDistance" : 2.5,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,

            "isScrollingWithOneFingerEnabled" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isClickWindowToFrontEnabled" : false,
            "isClickOnLiftEnabled" : false,
            "isPressAndHoldEnabled" : false,
            "areAdditionalDigitizerRotationSettingsVisible" : false
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
        // A zero zone means two taps can never be close enough to double click. It used to be
        // selectable while the distance check was broken and therefore inert, so a stored 0 is
        // not a deliberate choice — lift it to the smallest value the slider now offers.
        doubleClickDistance = max(1, defaults.double(forKey: "doubleClickDistance"))
        tapDistance = defaults.double(forKey: "tapDistance")
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")


        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $tapDistance.assign(to: \.tapTolerance, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager)
        ]
        
        
        
        isScrollingWithOneFingerEnabled = defaults.bool(forKey: "isScrollingWithOneFingerEnabled")
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isClickWindowToFrontEnabled = defaults.bool(forKey: "isClickWindowToFrontEnabled")
        isClickOnLiftEnabled = defaults.bool(forKey: "isClickOnLiftEnabled")
        isPressAndHoldEnabled = defaults.bool(forKey: "isPressAndHoldEnabled")
        areAdditionalDigitizerRotationSettingsVisible = defaults.bool(forKey: "areAdditionalDigitizerRotationSettingsVisible")
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(tapDistance, forKey: "tapDistance")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")

        defaults.set(isScrollingWithOneFingerEnabled, forKey: "isScrollingWithOneFingerEnabled")
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isMagnificationEnabled, forKey: "isMagnificationEnabled")
        defaults.set(isClickWindowToFrontEnabled, forKey: "isClickWindowToFrontEnabled")
        defaults.set(isClickOnLiftEnabled, forKey: "isClickOnLiftEnabled")
        defaults.set(isPressAndHoldEnabled, forKey: "isPressAndHoldEnabled")
        defaults.set(areAdditionalDigitizerRotationSettingsVisible, forKey: "areAdditionalDigitizerRotationSettingsVisible")
    }

}


// MARK: - Per-Digitizer Screen Mapping
extension TouchUp {

    private static let digitizerConfigsKey = "digitizerConfigs"

    /// The screen a freshly connected (or unmatched) digitizer maps to by default: the one
    /// that connected most recently, falling back to the last screen in the arrangement.
    var newestScreen: TUCScreen? {
        if let id = idOfLastAddedScreen, let screen = connectedScreens.first(where: { $0.id == id }) {
            return screen
        }
        return connectedScreens.last
    }

    /// Resolves the stored screen identity of a digitizer against the currently connected
    /// screens. Priority: UUID (exact) → display ID (fallback) → most recent screen (implicit).
    func resolvedMapping(forLocationID locationID: HIDLocationID) -> (screen: TUCScreen?, match: ScreenMatch) {
        let config = digitizerConfigs[locationID]

        if let uuid = config?.screenUUID,
           let screen = connectedScreens.first(where: { $0.uuid == uuid }) {
            return (screen, .exact)
        }

        if let id = config?.screenID,
           let screen = connectedScreens.first(where: { $0.id == id }) {
            return (screen, .idFallback)
        }

        if let screen = newestScreen {
            return (screen, .implicit)
        }

        return (nil, .unmapped)
    }

    /// Explicitly assigns a screen to a digitizer (user action) and persists it immediately.
    /// Storing the UUID makes the mapping confirmed, so it survives rearrange/rotate/mirror.
    func assignScreen(_ screen: TUCScreen?, toDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        config.screenUUID = screen?.uuid
        config.screenID = screen.map { UInt($0.id) }
        digitizerConfigs[locationID] = config
        persistMapping(forLocationID: locationID)
    }

    /// Sets the additional digitizer rotation (user action) and persists it immediately.
    func setRotation(_ rotation: CGFloat, forDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        config.additionalRotation = rotation
        digitizerConfigs[locationID] = config
        persistMapping(forLocationID: locationID)
    }

    /// Freezes the currently resolved screen (id + uuid) and rotation of one digitizer into
    /// persistent storage. Covers both cases: an explicit user edit, and an implicit mapping
    /// that worked fine and should stick (called for all digitizers before the window closes).
    func persistMapping(forLocationID locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }

        // Promote an as-yet-unconfirmed mapping (no stored UUID) to its currently resolved
        // screen — this is the "implicit mapping was fine, freeze it" case. A config that
        // already carries a UUID is a confirmed preference and is never overwritten here: if
        // its panel is merely absent right now (`.idFallback` / `.unmapped`) the stored UUID
        // must survive and reassert via an exact match once the panel returns.
        if config.screenUUID == nil, let screen = resolvedMapping(forLocationID: locationID).screen {
            config.screenID = UInt(screen.id)
            config.screenUUID = screen.uuid
        }

        digitizerConfigs[locationID] = config
        persistedConfigs[locationID] = config
        saveDigitizerConfigs()
    }

    /// Persists the mapping of every currently connected digitizer. Call before the settings
    /// window closes / on termination so implicit mappings become explicit next launch.
    func persistAllDigitizerMappings() {
        for locationID in digitizerConfigs.keys {
            persistMapping(forLocationID: locationID)
        }
    }

    /// Recomputes `connectionState` from the connected digitizers and their resolvable screens.
    func updateConnectionState() {
        guard !connectedDigitizers.isEmpty else {
            connectionState = .disconnected
            return
        }
        let anyResolved = connectedDigitizers.contains {
            resolvedMapping(forLocationID: $0.locationID).screen != nil
        }
        connectionState = anyResolved ? .connectedPreferred : .uncertain
    }

    func loadDigitizerConfigs() {
        guard let data = UserDefaults.standard.data(forKey: Self.digitizerConfigsKey),
              let decoded = try? JSONDecoder().decode([String: DigitizerConfig].self, from: data)
        else { return }

        // JSON object keys are strings; map them back to numeric location IDs.
        persistedConfigs = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            HIDLocationID(key).map { ($0, value) }
        })
    }

    private func saveDigitizerConfigs() {
        let encodable = Dictionary(uniqueKeysWithValues: persistedConfigs.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.digitizerConfigsKey)
        }
    }
}



extension TouchUp: TUCTouchDelegate {
    
    func touchesDidChange() {
        self.touches = self.touchManager.touchSet.allObjects as! [TUCTouch]
    }
    
    
    func touchscreen(forLocationID locationID: UInt32) -> TUCScreen? {
        resolvedMapping(forLocationID: locationID).screen
    }

    func digitizerRotation(forLocationID locationID: UInt32) -> CGFloat {
        digitizerConfigs[locationID]?.additionalRotation ?? 0
    }
    
    func action(for gesture: TUCCursorGesture) -> TUCCursorAction {
        switch gesture {
        case .TUCCursorGestureTouchDown:
            return isClickWindowToFrontEnabled ? .moveClickIfNeeded : .move
            
        case .TUCCursorGestureTap:
            return .click
            
        case .TUCCursorGestureLongPress:
            // Posted once the resting finger has made the gesture unambiguous. Mapping it to a
            // drag presses the button there and holds it until lift-off, which is what apps
            // expecting a real press-and-hold need; the lift-off click is suppressed in that
            // case so the touch still actuates exactly once. Off by default, because it turns
            // a long rest into a held button rather than the click it produces today.
            return isPressAndHoldEnabled ? .drag : .none

        case .TUCCursorGestureDrag:
            return isClickOnLiftEnabled ? .pointAndClick : (isScrollingWithOneFingerEnabled ? .scroll : .move)
            
        case .TUCCursorGestureHoldAndDrag:
            return .drag
            
        case .TUCCursorGestureTapSecondFinger:
            return isSecondaryClickEnabled ? .secondaryClick : .none
            
        case .TUCCursorGestureTwoFingerDrag:
            return isScrollingWithOneFingerEnabled ? .drag : .scroll
            
        case .TUCCursorGesturePinch:
            return isMagnificationEnabled ? .magnify : .none
            
        default:
            return .none
        }
    }
    
    
    
    func touchscreenDidConnect(withLocationID locationID: UInt32) {
        self.connectedDigitizers.append(Digitizer(locationID: locationID))

        // Restore a previously persisted config for this digitizer, or start a blank one
        // (which resolves implicitly to the most recently added screen).
        if digitizerConfigs[locationID] == nil {
            digitizerConfigs[locationID] = persistedConfigs[locationID] ?? DigitizerConfig()
        }

        updateConnectionState()
    }

    func touchscreenDidDisconnect(withLocationID locationID: UInt32) {
        if let index = self.connectedDigitizers.firstIndex(where: {$0.locationID == locationID}) {
            self.connectedDigitizers.remove(at: index)
        }
        // Drop the live config; the persisted copy in `persistedConfigs` survives for reconnect.
        digitizerConfigs[locationID] = nil

        updateConnectionState()
    }
    
}


extension TouchUp {
    func uiLabels<T>(for keyPath: KeyPath<TouchUp, T>) -> (title:String, description:String) {
        switch keyPath {
        case \.isPublishingMouseEventsEnabled:
            return("Control Mouse with Touch",
                   "Turns the driver on or off.")
            
        case \.isScrollingWithOneFingerEnabled:
            return("Scroll with one finger",
                   "Scroll by dragging one finger over the touchscreen. If this option is disabled, you will move the cursor instead.")
            
        case \.isSecondaryClickEnabled:
            return("Secondary Click",
                   "While your pointing finger is resting on the screen, tap another finger in proximity to it to generate a secondary click event at the location of the first finger.")
            
        case \.isMagnificationEnabled:
            return("Magnification",
                   "Pinch two fingers to increase or decrease the size of the content. (EXPERIMENTAL)")
            
        case \.isClickWindowToFrontEnabled:
            return("Bring Windows to Front",
                   "When touching a window that is not frontmost, bring it to front first. (EXPERIMENTAL)")
            
        case \.isClickOnLiftEnabled:
            return("Point and click",
                   "Very reduced input set for exhibits: Move cursor by dragging, and click by releasing. Overrides scrolling and dragging functionality.")

        case \.isPressAndHoldEnabled:
            return("Press and Hold",
                   "Hold the mouse button down for as long as your finger rests on the screen, instead of clicking once you lift it. Needed by apps that react to a button being held. (EXPERIMENTAL)")
            
        case \.holdDuration:
            return("Hold Duration",
                   "How long do you have to hold finger to initiate hold&drag")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")

        case \.tapDistance:
            return("Tap Zone",
                   "How many mm your finger may slide while touching and still count as a tap instead of a drag. Increase this if taps do not click reliably.")
            
        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")
        
        case \.areAdditionalDigitizerRotationSettingsVisible:
            return("Digitizer Rotation",
                   "Adds a rotation control to each touchscreen. Only needed if the digitizer orientation in does not match your screen.")
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedHotPlug // connected as result from hot plugging within a few seconds
    case connectedPreferred // connected with stored cues matching perfectly
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        default:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }
        
        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedPreferred || self == .connectedHotPlug
    }
}


extension TUCScreen: @retroactive Identifiable {}
