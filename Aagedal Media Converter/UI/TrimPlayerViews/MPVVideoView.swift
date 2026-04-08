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

        // After MPV's Vulkan pipeline is up, defer all future drawableSize changes
        // to avoid racing with MoltenVK's in-flight render passes during resize.
        metalLayer.deferResizes = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // Handle resize - matches demo's viewDidLayout
        guard let window = view.window else { return }

        let scale = window.screen?.backingScaleFactor ?? 2.0
        let layerSize = view.bounds.size

        // Floor to even pixel dimensions. A drawable slightly smaller than the
        // layer's frame gets imperceptibly stretched to fill, which eliminates
        // the black sub-pixel border that appears when MPV's aspect-ratio
        // enforcement leaves 1-2px of the drawable unfilled.
        let newDrawableSize = CGSize(
            width: floor(layerSize.width * scale / 2) * 2,
            height: floor(layerSize.height * scale / 2) * 2
        )

        // Update layer frame and contentsScale immediately for correct positioning.
        // The frame change may trigger CAMetalLayer's auto-resize of drawableSize,
        // but MPVMetalLayer.deferResizes coalesces and defers all size changes to
        // the next run loop iteration, preventing MoltenVK render-pass races.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(x: 0, y: 0, width: layerSize.width, height: layerSize.height)
        CATransaction.commit()

        // Set our floor-to-even size (coalesced with any auto-resize; deferred by MPVMetalLayer)
        metalLayer.drawableSize = newDrawableSize
    }
}

// MARK: - SwiftUI Wrapper (NSViewControllerRepresentable like demo)

struct MPVVideoView: NSViewControllerRepresentable {
    let player: MPVPlayer
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSViewController(context: Context) -> MPVViewController {
        let viewController = MPVViewController(player: player)
        context.coordinator.viewController = viewController
        return viewController
    }

    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        context.coordinator.viewController = nsViewController
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(keyHandler: keyHandler)
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        private var monitor: Any?
        private let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
        weak var viewController: MPVViewController?

        init(keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
            self.keyHandler = keyHandler
            super.init()

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events if our window is the key window
                // This prevents capturing events when fullscreen player is open
                // NSEvent monitors always run on the main thread, so we can safely assume main actor isolation
                let isKeyWindow = MainActor.assumeIsolated {
                    self.viewController?.view.window?.isKeyWindow ?? false
                }
                guard isKeyWindow else {
                    return event
                }

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
