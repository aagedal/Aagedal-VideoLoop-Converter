// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - View Controller (matches MPVKit demo pattern)

final class MPVViewController: NSViewController {
    let player: MPVPlayer
    private var metalLayer: MPVMetalLayer!

    init(player: MPVPlayer) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Create the view - matches demo's loadView
        self.view = NSView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create and configure Metal layer - matches demo's viewDidLoad
        metalLayer = MPVMetalLayer()
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        view.layer = metalLayer

        // Initialize MPV with the layer - this is where the demo calls setupMpv()
        player.attachDrawable(metalLayer)
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // Handle resize - matches demo's viewDidLayout
        if let window = view.window {
            let scale = window.screen?.backingScaleFactor ?? 2.0
            let layerSize = view.bounds.size

            metalLayer.frame = CGRect(x: 0, y: 0, width: layerSize.width, height: layerSize.height)
            metalLayer.drawableSize = CGSize(width: layerSize.width * scale, height: layerSize.height * scale)
        }
    }
}

// MARK: - SwiftUI Wrapper (NSViewControllerRepresentable like demo)

struct MPVVideoView: NSViewControllerRepresentable {
    let player: MPVPlayer
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSViewController(context: Context) -> MPVViewController {
        let viewController = MPVViewController(player: player)
        return viewController
    }

    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        // Handle updates if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }

    final class Coordinator: NSObject {
        private var monitor: Any?
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
            super.init()

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return event }

                // Process keyboard events - the handler decides if they should be handled
                let handled = self.keyHandler(characters, event.modifierFlags, event.specialKey)
                return handled ? nil : event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
