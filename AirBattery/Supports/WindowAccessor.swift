//
//  WindowAccessor.swift
//  xHistory
//
//  Created by apple on 2024/11/7.
//

import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    var onWindowOpen: ((NSWindow?) -> Void)?
    var onWindowActive: ((NSWindow?) -> Void)?
    var onWindowDeactivate: ((NSWindow?) -> Void)?
    var onWindowClose: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else {
                self.onWindowOpen?(nil)
                return
            }
            // Do not assign `window.delegate` here. Replacing SwiftUI's delegate (e.g. on the
            // Settings window) breaks frame persistence and move handling so the window can snap
            // back to its previous origin after each drag.
            context.coordinator.window = window
            self.onWindowOpen?(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onWindowOpen: onWindowOpen,
            onWindowActive: onWindowActive,
            onWindowDeactivate: onWindowDeactivate,
            onWindowClose: onWindowClose
        )
    }

    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var onWindowOpen: ((NSWindow?) -> Void)?
        var onWindowActive: ((NSWindow?) -> Void)?
        var onWindowDeactivate: ((NSWindow?) -> Void)?
        var onWindowClose: (() -> Void)?

        init(onWindowOpen: ((NSWindow?) -> Void)? = nil,
             onWindowActive: ((NSWindow?) -> Void)? = nil,
             onWindowDeactivate: ((NSWindow?) -> Void)? = nil,
             onWindowClose: (() -> Void)? = nil) {
            self.onWindowOpen = onWindowOpen
            self.onWindowClose = onWindowClose
            self.onWindowActive = onWindowActive
            self.onWindowDeactivate = onWindowDeactivate
        }
        // If you need window lifecycle callbacks without replacing `NSWindow.delegate`, use
        // `NotificationCenter` (e.g. `NSWindow.didBecomeKeyNotification`) from `onWindowOpen`.
    }
}
