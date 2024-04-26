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
    
    let closeAction: ()->Void
    
    var pixelsPerMM: CGFloat
    
    init(model: TouchUp, closeAction: @escaping ()->Void) {
        self.model = model
        self.pixelsPerMM = model.touchscreen()?.pixelsPerMM() ?? 30
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
    
    var body: some View {
        ZStack(alignment: .bottom) {
            
            Rectangle()
                .foregroundColor(Color(white: 0.1))
                .frame(maxWidth:.infinity, maxHeight: .infinity)
                .overlay(GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        
                        
                        ForEach(model.touches, id:\.uuid) { point in
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
            .padding(.bottom, 140)
        }
        
            
    }
}

struct DebugView_Previews: PreviewProvider {
    static var previews: some View {
        DebugView(model: TouchUp(), closeAction: {})
    }
}
