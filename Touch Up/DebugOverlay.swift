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
