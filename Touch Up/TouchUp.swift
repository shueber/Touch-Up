//
//  Model.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Carbon
import Combine
import IOKit
import TouchUpCore

class TouchUp: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    @Published var isPublishingMouseEventsEnabled = true
    
    @Published var connectionState: ConnectionState = .disconnected
    
    @Published var holdDuration: TimeInterval = 0.1
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var stationaryThreshold: CGFloat = 0.2 // accepted jitter [mm] to still count as stationary
    @Published var edgeDeadZone: CGFloat = 0 // border along the screen edges [pt] in which the cursor is never posted
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    @Published var isScrollingWithOneFingerEnabled = false
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isClickWindowToFrontEnabled = false
    @Published var isClickOnLiftEnabled = false
    @Published var isExclusiveAccessEnabled: Bool = false

    /// Draws a circle at every finger that touches the touchscreen (for recordings
    /// and presentations). Driven purely by touch data, so mouse clicks never show
    /// an indicator.
    @Published var isTouchIndicatorEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isTouchIndicatorEnabled, forKey: "isTouchIndicatorEnabled")
        }
    }

    /// Maps a `MultiFingerGesture.rawValue` to the id of the `ShortcutPreset` assigned to it.
    /// Missing keys mean "Off" (no shortcut, default cursor behavior for that finger count).
    @Published var gestureShortcutMappings: [String: String] = [:] {
        didSet {
            saveGestureShortcutMappings()
            updateSwipeEnableFlags()
        }
    }

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

    /// macOS requires Input Monitoring (TCC "listen event") access to read HID touchscreens.
    /// Without it, device registration fails — the driver stays dormant instead of crashing.
    @Published var isInputMonitoringGranted = false


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

    func checkInputMonitoringAccess() {
        isInputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestInputMonitoringAccess() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        checkInputMonitoringAccess()
        // The system prompt can be easy to miss; open the settings pane as well.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func grantAccessibilityAccess() {
        self.touchManager.triggerSystemAccessibilityAccessAlert()
        (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        self.isAccessibilityAccessGranted = true
    }

    @objc func refreshPermissionState() {
        checkAccessibilityAccessGranted()
        checkInputMonitoringAccess()
    }
    
    
    override init() {
        self.touchManager = TUCTouchInputManager()

        super.init()

        self.loadDigitizerConfigs()
        self.screenParametersDidChange()
        
        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchUp.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TouchUp.refreshPermissionState), name: NSApplication.didBecomeActiveNotification, object: nil)

        initPreferences()

        checkAccessibilityAccessGranted()
        checkInputMonitoringAccess()
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
            "stationaryThreshold" : 0.1,
            "edgeDeadZone" : 0,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,

            "isScrollingWithOneFingerEnabled" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isClickWindowToFrontEnabled" : false,
            "isClickOnLiftEnabled" : false,
            "isExclusiveAccessEnabled" : false,
            "areAdditionalDigitizerRotationSettingsVisible" : false,
            "isTouchIndicatorEnabled" : false,

            // Swipes mirror the classic macOS trackpad shortcuts; long-presses hold the
            // fn key until the fingers lift. Taps default to off.
            "gestureShortcutMappings" : [
                MultiFingerGesture.threeUp.rawValue: "ctrl-up",
                MultiFingerGesture.threeDown.rawValue: "ctrl-down",
                MultiFingerGesture.threeLeft.rawValue: "ctrl-left",
                MultiFingerGesture.threeRight.rawValue: "ctrl-right",
                MultiFingerGesture.fourUp.rawValue: "ctrl-up",
                MultiFingerGesture.fourDown.rawValue: "ctrl-down",
                MultiFingerGesture.fourLeft.rawValue: "ctrl-left",
                MultiFingerGesture.fourRight.rawValue: "ctrl-right",
                MultiFingerGesture.threeLongPress.rawValue: "fn",
                MultiFingerGesture.fourLongPress.rawValue: "fn"
            ]
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
        doubleClickDistance = defaults.double(forKey: "doubleClickDistance")
        stationaryThreshold = defaults.double(forKey: "stationaryThreshold")
        edgeDeadZone = defaults.double(forKey: "edgeDeadZone")
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")
        isExclusiveAccessEnabled = defaults.bool(forKey: "isExclusiveAccessEnabled")


        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $stationaryThreshold.assign(to: \.stationaryThreshold, on: touchManager),
            $edgeDeadZone.assign(to: \.edgeDeadZone, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
            
            $isExclusiveAccessEnabled.sink { [weak touchManager] seized in
                touchManager?.setTouchscreensSeized(seized)
            }
        ]
        
        
        
        isScrollingWithOneFingerEnabled = defaults.bool(forKey: "isScrollingWithOneFingerEnabled")
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isClickWindowToFrontEnabled = defaults.bool(forKey: "isClickWindowToFrontEnabled")
        isClickOnLiftEnabled = defaults.bool(forKey: "isClickOnLiftEnabled")
        areAdditionalDigitizerRotationSettingsVisible = defaults.bool(forKey: "areAdditionalDigitizerRotationSettingsVisible")
        isTouchIndicatorEnabled = defaults.bool(forKey: "isTouchIndicatorEnabled")

        gestureShortcutMappings = defaults.dictionary(forKey: "gestureShortcutMappings") as? [String: String] ?? [:]
        updateSwipeEnableFlags()
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(stationaryThreshold, forKey: "stationaryThreshold")
        defaults.set(edgeDeadZone, forKey: "edgeDeadZone")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")
        defaults.set(isExclusiveAccessEnabled, forKey: "isExclusiveAccessEnabled")

        defaults.set(isScrollingWithOneFingerEnabled, forKey: "isScrollingWithOneFingerEnabled")
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isMagnificationEnabled, forKey: "isMagnificationEnabled")
        defaults.set(isClickWindowToFrontEnabled, forKey: "isClickWindowToFrontEnabled")
        defaults.set(isClickOnLiftEnabled, forKey: "isClickOnLiftEnabled")
        defaults.set(areAdditionalDigitizerRotationSettingsVisible, forKey: "areAdditionalDigitizerRotationSettingsVisible")
    }
}


// MARK: - Multi-Finger Shortcut Mappings
extension TouchUp {

    private func saveGestureShortcutMappings() {
        UserDefaults.standard.set(gestureShortcutMappings, forKey: "gestureShortcutMappings")
    }

    /// Tells the driver which finger-count groups currently have at least one shortcut
    /// assigned. Groups without assignments keep the legacy cursor behavior untouched.
    private func updateSwipeEnableFlags() {
        touchManager.threeFingerSwipesEnabled = MultiFingerGesture.threeFingerCases.contains {
            gestureShortcutMappings[$0.rawValue] != nil
        }
        touchManager.fourFingerSwipesEnabled = MultiFingerGesture.fourFingerCases.contains {
            gestureShortcutMappings[$0.rawValue] != nil
        }
    }

    func shortcutPreset(for gesture: TUCCursorGesture) -> ShortcutPreset? {
        guard let swipe = MultiFingerGesture(coreGesture: gesture),
              let presetID = gestureShortcutMappings[swipe.rawValue]
        else { return nil }
        return ShortcutPreset.catalog.first { $0.id == presetID }
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
            return .click
            
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

        case .TUCCursorGestureThreeFingerSwipeUp, .TUCCursorGestureThreeFingerSwipeDown,
             .TUCCursorGestureThreeFingerSwipeLeft, .TUCCursorGestureThreeFingerSwipeRight,
             .TUCCursorGestureFourFingerSwipeUp, .TUCCursorGestureFourFingerSwipeDown,
             .TUCCursorGestureFourFingerSwipeLeft, .TUCCursorGestureFourFingerSwipeRight,
             .TUCCursorGestureThreeFingerTap, .TUCCursorGestureFourFingerTap:
            return shortcutPreset(for: gesture) != nil ? .keyboardShortcut : .none

        default:
            return .none
        }
    }

    func performKeyboardShortcut(for gesture: TUCCursorGesture) {
        shortcutPreset(for: gesture)?.post()
    }

    func beginKeyboardHold(for gesture: TUCCursorGesture) {
        shortcutPreset(for: gesture)?.postKeyDown()
    }

    func endKeyboardHold(for gesture: TUCCursorGesture) {
        shortcutPreset(for: gesture)?.postKeyUp()
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
            
        case \.holdDuration:
            return("Hold Duration",
                   "How long do you have to hold finger to initiate hold&drag")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")

        case \.stationaryThreshold:
            return("Jitter Tolerance",
                   "Increase, if taps and long presses are not registering reliably; decrease for more responsive dragging.")

        case \.edgeDeadZone:
            return("Edge Dead Zone",
                   "Increase this value, to prevent touches from triggering mouse events at the screen edge.")

        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")
            
        case \.isExclusiveAccessEnabled:
            return("Exclusive Access",
                   "This option should mitigate undesired mouse events created on some devices.")

        case \.isTouchIndicatorEnabled:
            return("Show Touch Indicators",
                   "Display a circle at every finger touching the screen and hide the mouse pointer while a finger is down — made for screen recordings and presentations. Mouse input never shows indicators or hides the pointer.")
        
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


// MARK: - Multi-Finger Gestures

/// The multi-finger gestures that can each be mapped to one keyboard shortcut.
enum MultiFingerGesture: String, CaseIterable, Identifiable {
    case threeUp, threeDown, threeLeft, threeRight, threeTap, threeLongPress
    case fourUp, fourDown, fourLeft, fourRight, fourTap, fourLongPress

    var id: String { rawValue }

    static var threeFingerCases: [MultiFingerGesture] {
        [.threeUp, .threeDown, .threeLeft, .threeRight, .threeTap, .threeLongPress]
    }
    static var fourFingerCases: [MultiFingerGesture] {
        [.fourUp, .fourDown, .fourLeft, .fourRight, .fourTap, .fourLongPress]
    }

    init?(coreGesture: TUCCursorGesture) {
        switch coreGesture {
        case .TUCCursorGestureThreeFingerSwipeUp:    self = .threeUp
        case .TUCCursorGestureThreeFingerSwipeDown:  self = .threeDown
        case .TUCCursorGestureThreeFingerSwipeLeft:  self = .threeLeft
        case .TUCCursorGestureThreeFingerSwipeRight: self = .threeRight
        case .TUCCursorGestureThreeFingerTap:        self = .threeTap
        case .TUCCursorGestureThreeFingerLongPress:  self = .threeLongPress
        case .TUCCursorGestureFourFingerSwipeUp:     self = .fourUp
        case .TUCCursorGestureFourFingerSwipeDown:   self = .fourDown
        case .TUCCursorGestureFourFingerSwipeLeft:   self = .fourLeft
        case .TUCCursorGestureFourFingerSwipeRight:  self = .fourRight
        case .TUCCursorGestureFourFingerTap:         self = .fourTap
        case .TUCCursorGestureFourFingerLongPress:   self = .fourLongPress
        default: return nil
        }
    }

    var coreGesture: TUCCursorGesture {
        switch self {
        case .threeUp:        return .TUCCursorGestureThreeFingerSwipeUp
        case .threeDown:      return .TUCCursorGestureThreeFingerSwipeDown
        case .threeLeft:      return .TUCCursorGestureThreeFingerSwipeLeft
        case .threeRight:     return .TUCCursorGestureThreeFingerSwipeRight
        case .threeTap:       return .TUCCursorGestureThreeFingerTap
        case .threeLongPress: return .TUCCursorGestureThreeFingerLongPress
        case .fourUp:         return .TUCCursorGestureFourFingerSwipeUp
        case .fourDown:       return .TUCCursorGestureFourFingerSwipeDown
        case .fourLeft:       return .TUCCursorGestureFourFingerSwipeLeft
        case .fourRight:      return .TUCCursorGestureFourFingerSwipeRight
        case .fourTap:        return .TUCCursorGestureFourFingerTap
        case .fourLongPress:  return .TUCCursorGestureFourFingerLongPress
        }
    }

    var title: String {
        let fingers = rawValue.hasPrefix("three") ? 3 : 4
        switch self {
        case .threeUp, .fourUp:         return "\(fingers)-Finger Swipe Up"
        case .threeDown, .fourDown:     return "\(fingers)-Finger Swipe Down"
        case .threeLeft, .fourLeft:     return "\(fingers)-Finger Swipe Left"
        case .threeRight, .fourRight:   return "\(fingers)-Finger Swipe Right"
        case .threeTap, .fourTap:       return "\(fingers)-Finger Tap"
        case .threeLongPress, .fourLongPress:
            return "\(fingers)-Finger Long Press"
        }
    }
}


// MARK: - Keyboard Shortcut Presets

/// One selectable entry of the shortcut dropdowns in the settings.
struct ShortcutPreset: Identifiable {

    enum Kind {
        case key(keyCode: CGKeyCode, modifiers: CGEventFlags)
        case mediaKey(Int32)    // NX_KEYTYPE_* value
    }

    let id: String
    let name: String
    let display: String
    let kind: Kind

    /// Curated list of common macOS shortcuts, grouped by leading comment.
    static let catalog: [ShortcutPreset] = [
        // Function key (default for long-presses)
        .init(id: "fn", name: "Function Key", display: "fn",
              kind: .key(keyCode: CGKeyCode(kVK_Function), modifiers: [])),

        // Mission Control & Spaces
        .init(id: "ctrl-up", name: "Mission Control", display: "⌃↑",
              kind: .key(keyCode: CGKeyCode(kVK_UpArrow), modifiers: .maskControl)),
        .init(id: "ctrl-down", name: "Application Windows", display: "⌃↓",
              kind: .key(keyCode: CGKeyCode(kVK_DownArrow), modifiers: .maskControl)),
        .init(id: "ctrl-left", name: "Switch Space Left", display: "⌃←",
              kind: .key(keyCode: CGKeyCode(kVK_LeftArrow), modifiers: .maskControl)),
        .init(id: "ctrl-right", name: "Switch Space Right", display: "⌃→",
              kind: .key(keyCode: CGKeyCode(kVK_RightArrow), modifiers: .maskControl)),
        .init(id: "ctrl-shift-left", name: "Move Window Left a Space", display: "⌃⇧←",
              kind: .key(keyCode: CGKeyCode(kVK_LeftArrow), modifiers: [.maskControl, .maskShift])),
        .init(id: "ctrl-shift-right", name: "Move Window Right a Space", display: "⌃⇧→",
              kind: .key(keyCode: CGKeyCode(kVK_RightArrow), modifiers: [.maskControl, .maskShift])),
        .init(id: "f4", name: "Launchpad", display: "F4",
              kind: .key(keyCode: CGKeyCode(kVK_F4), modifiers: [])),
        .init(id: "f11", name: "Show Desktop", display: "F11",
              kind: .key(keyCode: CGKeyCode(kVK_F11), modifiers: [])),

        // Windows & Applications
        .init(id: "cmd-w", name: "Close Window", display: "⌘W",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_W), modifiers: .maskCommand)),
        .init(id: "cmd-m", name: "Minimize Window", display: "⌘M",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_M), modifiers: .maskCommand)),
        .init(id: "cmd-q", name: "Quit Application", display: "⌘Q",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: .maskCommand)),
        .init(id: "cmd-tab", name: "Next Application", display: "⌘⇥",
              kind: .key(keyCode: CGKeyCode(kVK_Tab), modifiers: .maskCommand)),
        .init(id: "cmd-shift-tab", name: "Previous Application", display: "⌘⇧⇥",
              kind: .key(keyCode: CGKeyCode(kVK_Tab), modifiers: [.maskCommand, .maskShift])),
        .init(id: "cmd-grave", name: "Cycle Windows of Application", display: "⌘`",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_Grave), modifiers: .maskCommand)),
        .init(id: "cmd-t", name: "New Tab", display: "⌘T",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_T), modifiers: .maskCommand)),
        .init(id: "cmd-r", name: "Reload", display: "⌘R",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_R), modifiers: .maskCommand)),
        .init(id: "cmd-h", name: "Hide Application", display: "⌘H",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_H), modifiers: .maskCommand)),
        .init(id: "alt-cmd-h", name: "Hide Other Applications", display: "⌥⌘H",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_H), modifiers: [.maskCommand, .maskAlternate])),

        // Navigation & Scrolling
        .init(id: "page-up", name: "Page Up", display: "⇞",
              kind: .key(keyCode: CGKeyCode(kVK_PageUp), modifiers: [])),
        .init(id: "page-down", name: "Page Down", display: "⇟",
              kind: .key(keyCode: CGKeyCode(kVK_PageDown), modifiers: [])),
        .init(id: "home", name: "Beginning of Page / Document", display: "↖",
              kind: .key(keyCode: CGKeyCode(kVK_Home), modifiers: [])),
        .init(id: "end", name: "End of Page / Document", display: "↘",
              kind: .key(keyCode: CGKeyCode(kVK_End), modifiers: [])),
        .init(id: "alt-left", name: "Move Word Left", display: "⌥←",
              kind: .key(keyCode: CGKeyCode(kVK_LeftArrow), modifiers: .maskAlternate)),
        .init(id: "alt-right", name: "Move Word Right", display: "⌥→",
              kind: .key(keyCode: CGKeyCode(kVK_RightArrow), modifiers: .maskAlternate)),
        .init(id: "cmd-left", name: "Move to Line Start", display: "⌘←",
              kind: .key(keyCode: CGKeyCode(kVK_LeftArrow), modifiers: .maskCommand)),
        .init(id: "cmd-right", name: "Move to Line End", display: "⌘→",
              kind: .key(keyCode: CGKeyCode(kVK_RightArrow), modifiers: .maskCommand)),
        .init(id: "cmd-up", name: "Move to Document Start", display: "⌘↑",
              kind: .key(keyCode: CGKeyCode(kVK_UpArrow), modifiers: .maskCommand)),
        .init(id: "cmd-down", name: "Move to Document End", display: "⌘↓",
              kind: .key(keyCode: CGKeyCode(kVK_DownArrow), modifiers: .maskCommand)),

        // Editing
        .init(id: "cmd-c", name: "Copy", display: "⌘C",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: .maskCommand)),
        .init(id: "cmd-v", name: "Paste", display: "⌘V",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_V), modifiers: .maskCommand)),
        .init(id: "cmd-x", name: "Cut", display: "⌘X",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_X), modifiers: .maskCommand)),
        .init(id: "cmd-z", name: "Undo", display: "⌘Z",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: .maskCommand)),
        .init(id: "cmd-shift-z", name: "Redo", display: "⌘⇧Z",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: [.maskCommand, .maskShift])),
        .init(id: "cmd-a", name: "Select All", display: "⌘A",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: .maskCommand)),

        // System
        .init(id: "cmd-space", name: "Spotlight Search", display: "⌘Space",
              kind: .key(keyCode: CGKeyCode(kVK_Space), modifiers: .maskCommand)),
        .init(id: "ctrl-cmd-q", name: "Lock Screen", display: "⌃⌘Q",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: [.maskControl, .maskCommand])),
        .init(id: "cmd-shift-3", name: "Screenshot: Entire Screen", display: "⌘⇧3",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_3), modifiers: [.maskCommand, .maskShift])),
        .init(id: "cmd-shift-4", name: "Screenshot: Selected Area", display: "⌘⇧4",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_4), modifiers: [.maskCommand, .maskShift])),
        .init(id: "cmd-shift-5", name: "Screenshot: Screenshot Toolbar", display: "⌘⇧5",
              kind: .key(keyCode: CGKeyCode(kVK_ANSI_5), modifiers: [.maskCommand, .maskShift])),

        // Media & Display
        .init(id: "volume-up", name: "Volume Up", display: "🔊+", kind: .mediaKey(0)),
        .init(id: "volume-down", name: "Volume Down", display: "🔊−", kind: .mediaKey(1)),
        .init(id: "mute", name: "Mute", display: "🔇", kind: .mediaKey(7)),
        .init(id: "brightness-up", name: "Brightness Up", display: "☀+", kind: .mediaKey(2)),
        .init(id: "brightness-down", name: "Brightness Down", display: "☀−", kind: .mediaKey(3)),
        .init(id: "play-pause", name: "Play / Pause", display: "⏯",
              kind: .mediaKey(16)),   // NX_KEYTYPE_PLAY
        .init(id: "next-track", name: "Next Track", display: "⏭",
              kind: .mediaKey(17)),   // NX_KEYTYPE_NEXT
        .init(id: "previous-track", name: "Previous Track", display: "⏮",
              kind: .mediaKey(18))    // NX_KEYTYPE_PREVIOUS
    ]

    /// Posts the shortcut as a real keystroke (requires Accessibility access).
    func post() {
        switch kind {
        case .key:
            postKeyDown()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                self.postKeyUp()
            }

        case .mediaKey(let type):
            Self.postMediaKey(type, down: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                Self.postMediaKey(type, down: false)
            }
        }
    }

    /// Presses the key and leaves it held — used by long-press gestures.
    /// Call `postKeyUp()` when the fingers lift.
    func postKeyDown() {
        guard case .key(let keyCode, let modifiers) = kind else { return }
        let source = CGEventSource(stateID: .hidSystemState)

        // Real arrow keys arrive with the numericPad flag; Mission Control and
        // Spaces discard arrow-key shortcuts posted without it.
        var flags = modifiers

        // macOS quirk: synthetic events carrying only the control flag are ignored
        // by system shortcut handling — the SecondaryFn flag (present on real
        // keyboard events) must accompany it. See SO 61872579 / 45704155.
        if modifiers.contains(.maskControl) {
            flags.insert(.maskSecondaryFn)
        }

        switch keyCode {
        case CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
             CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow):
            flags.insert(.maskNumericPad)
        case CGKeyCode(kVK_Function):
            // Apps detect a held fn via the SecondaryFn flag, not the bare keycode.
            flags.insert(.maskSecondaryFn)
        default:
            break
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
    }

    /// Releases the key pressed by `postKeyDown()` and clears latched modifier state.
    func postKeyUp() {
        guard case .key(let keyCode, let modifiers) = kind else { return }
        let source = CGEventSource(stateID: .hidSystemState)

        var flags = modifiers
        if modifiers.contains(.maskControl) {
            flags.insert(.maskSecondaryFn)
        }
        switch keyCode {
        case CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
             CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow):
            flags.insert(.maskNumericPad)
        default:
            break
        }

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)

        // A physical fn release is a flagsChanged event without the SecondaryFn flag;
        // posting the same shape clears the system's held-fn state.
        if keyCode == CGKeyCode(kVK_Function) {
            let fnRelease = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            fnRelease?.type = .flagsChanged
            fnRelease?.flags = []
            fnRelease?.post(tap: .cghidEventTap)
        }

        // The synthetic keyDown latches a "modifier held" state in the system;
        // without an explicit release the control flag stays stuck and turns
        // subsequent clicks into secondary clicks. Post modifier key-up events
        // so the state is cleared even though no modifier key was ever pressed.
        if modifiers.contains(.maskControl) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: false)?.post(tap: .cghidEventTap)
        }
        if modifiers.contains(.maskShift) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)?.post(tap: .cghidEventTap)
        }
        if modifiers.contains(.maskAlternate) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Option), keyDown: false)?.post(tap: .cghidEventTap)
        }
        if modifiers.contains(.maskCommand) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    /// Media keys (volume, brightness, playback) travel as NSEvents of subtype 8,
    /// whose data1 packs the NX_KEYTYPE id plus a down/up flag.
    private static func postMediaKey(_ type: Int32, down: Bool) {
        let data1 = Int((type << 16) | ((down ? 0x0A : 0x0B) << 8))
        let event = NSEvent.otherEvent(with: .systemDefined,
                                       location: .zero,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0,
                                       context: nil,
                                       subtype: 8,
                                       data1: data1,
                                       data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
