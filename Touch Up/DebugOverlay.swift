//
//  DebugOverlay.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//


import Cocoa
import SwiftUI
import Combine
import TouchUpCore

class DebugOverlay: NSWindow {
    
    var model: TouchUp?
    static var completion: (()->Void)?
    
    private static func constructView(model: TouchUp, locationID: HIDLocationID?) -> DebugView {
        DebugView(model:model, locationID: locationID, closeAction: {
            DebugOverlay.completion?()
        })
    }
    
    static func overlay(model: TouchUp) -> DebugOverlay {
        let vc = NSHostingController(rootView: Self.constructView(model: model, locationID: nil))
        
        let window = DebugOverlay(contentRect: .zero,
                                    styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "Touches"
        window.tabbingMode = .disallowed
        window.model = model
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        
        return window
    }
    
    
    func makeVisible(onScreen targetScreen: TUCScreen, digitizerLocationID: HIDLocationID?) {
        // create new SwiftUI view for the new digitizerLocationId
        if let host = self.windowController?.contentViewController as? NSHostingController<DebugView>,
           let model = self.model {
            host.rootView = Self.constructView(model: model, locationID: digitizerLocationID)
        }
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        if let controller = self.contentViewController {
            if let screen = targetScreen.systemScreen() {
                self.level = .screenSaver // prevents notifications from coming in
                let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
                
                let options: [NSView.FullScreenModeOptionKey : NSNumber] = [
                    .fullScreenModeApplicationPresentationOptions : NSNumber(value: presentationOptions.rawValue),
                    .fullScreenModeWindowLevel : NSNumber(value: kCGPopUpMenuWindowLevel),
                    .fullScreenModeAllScreens : NSNumber(booleanLiteral: false)
                ]
                self.setIsVisible(false)
                controller.view.enterFullScreenMode(screen, withOptions: options)
            }
        }
    }
    
    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }
        super.close()
    }
}


// MARK: - Touch Position Indicators

/// Draws a translucent circle at every finger currently touching the touchscreen.
/// The overlay is driven purely by touch data, so mouse clicks never produce an
/// indicator. Intended for screen recordings and presentations.
final class TouchIndicatorOverlay {

    private let model: TouchUp
    private var window: NSWindow?
    private var indicatorView: TouchIndicatorView?
    private var unionFrame: NSRect = .zero
    private var observers = [AnyCancellable]()
    private var cursorHidden = false
    private var reassertTimer: Timer?

    init(model: TouchUp) {
        self.model = model

        // One sink for both triggers: touches moving, or the toggle flipping.
        let touchUpdates = model.$touches.map { _ in () }
        let toggleUpdates = model.$isTouchIndicatorEnabled.map { _ in () }

        observers.append(
            Publishers.Merge(touchUpdates, toggleUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refresh() }
        )
    }

    private func refresh() {
        guard model.isTouchIndicatorEnabled else {
            hideAll()
            stopCursorReassert()
            setCursorHidden(false)
            return
        }

        ensureWindow()

        // One window spans every screen, so no per-display placement can fail.
        // CG global coords (y-down) → AppKit coords (y-up) → window-local.
        var markers = [String: CGPoint]()
        let mainTop = NSScreen.screens.first.map { NSMaxY($0.frame) } ?? 0
        for touch in model.touches where touch.isActive() {
            let cgPoint = model.touchManager.convertScreenPointRelative(toAbsolute: touch.location,
                                                                       locationID: touch.locationID)
            let nsPoint = CGPoint(x: cgPoint.x, y: mainTop - cgPoint.y)
            let local = CGPoint(x: nsPoint.x - unionFrame.origin.x,
                                y: nsPoint.y - unionFrame.origin.y)
            markers[touch.uuid.uuidString] = local
        }

        indicatorView?.apply(markers: markers)
        window?.orderFrontRegardless()

        // Hide the pointer while a multi-finger gesture is on the screen — the only
        // case where hiding actually sticks, because mouse events are suppressed and
        // the pointer is never repositioned.
        //
        // Single-finger hide is intentionally disabled: macOS force-renders the
        // pointer whenever it is repositioned (NSCursor.hide is ignored during the
        // driver's cursor moves), so hiding a resting single finger only made the
        // pointer flicker in and out during taps and drags without ever staying
        // hidden while it mattered.
        if markers.count >= 2 {
            setCursorHidden(true)
            startCursorReassert()
        } else {
            stopCursorReassert()
            setCursorHidden(false)
        }
    }

    private func startCursorReassert() {
        guard reassertTimer == nil else { return }
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self, self.model.isTouchIndicatorEnabled else { return }
            self.setCursorHidden(true)
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private func stopCursorReassert() {
        reassertTimer?.invalidate()
        reassertTimer = nil
    }

    /// Balanced NSCursor hide/unhide so the pointer only disappears while a
    /// finger is actually on the touchscreen. While a finger is down, the hide
    /// state is re-asserted on every update: the driver's cursor warps can make
    /// macOS re-display the pointer mid-drag.
    private func setCursorHidden(_ hidden: Bool) {
        if hidden {
            if cursorHidden {
                NSCursor.unhide()
            }
            NSCursor.hide()
            cursorHidden = true
        } else if cursorHidden {
            cursorHidden = false
            NSCursor.unhide()
        }
    }

    /// One borderless window spanning the union of all screens.
    private func ensureWindow() {
        var union = NSRect.zero
        for screen in NSScreen.screens {
            union = NSUnionRect(union, screen.frame)
        }

        if let window, window.frame == union {
            return
        }

        window?.orderOut(nil)
        unionFrame = union

        let newWindow = NSWindow(contentRect: union,
                                 styleMask: .borderless,
                                 backing: .buffered,
                                 defer: false)
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        newWindow.hasShadow = false
        newWindow.ignoresMouseEvents = true
        newWindow.level = .screenSaver
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newWindow.isReleasedWhenClosed = false

        let view = TouchIndicatorView(frame: CGRect(origin: .zero, size: union.size))
        view.autoresizingMask = [.width, .height]
        newWindow.contentView = view

        window = newWindow
        indicatorView = view
    }

    private func hideAll() {
        indicatorView?.apply(markers: [:])
        window?.orderOut(nil)
    }
}


/// The layer-hosting view that owns one circle layer per touch and fades a
/// circle out over 0.4 s when its finger lifts.
final class TouchIndicatorView: NSView {

    private var layers: [String: CAShapeLayer] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func apply(markers: [String: CGPoint]) {
        for (id, point) in markers {
            if let layer = layers[id] {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.position = point
                CATransaction.commit()
            } else {
                let layer = makeCircle(at: point)
                layers[id] = layer
                self.layer?.addSublayer(layer)
            }
        }

        // Finger lifted: fade the circle out, then remove it.
        for (id, layer) in layers where markers[id] == nil {
            layers[id] = nil

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = 0.4
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            layer.add(fade, forKey: "fade")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                layer.removeFromSuperlayer()
            }
        }
    }

    private func makeCircle(at point: CGPoint) -> CAShapeLayer {
        let radius: CGFloat = 22
        let layer = CAShapeLayer()
        layer.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius,
                                              width: radius * 2, height: radius * 2),
                            transform: nil)
        layer.position = point
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
        layer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 2
        return layer
    }
}
