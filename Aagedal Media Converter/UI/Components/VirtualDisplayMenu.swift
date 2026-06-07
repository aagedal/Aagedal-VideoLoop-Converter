// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small menu placed next to the capture display picker. Lets the user spawn a
// headless virtual display to record a window/feed off-screen, then tear it
// down. Created displays appear in the normal display picker automatically
// (they get a real CGDirectDisplayID), so this view only adds/removes them and
// asks the host to refresh its display list.

import SwiftUI
import CoreGraphics

struct VirtualDisplayMenu: View {
    /// Disable while a recording/processing is in flight.
    var isDisabled: Bool = false
    /// Re-fetch the host's available-displays list after a create/destroy so the
    /// new display shows up (or a removed one disappears) in the picker.
    var onDisplaysChanged: () async -> Void
    /// Called with the new display's ID after a virtual display is created (so the host can select it).
    var onCreated: (CGDirectDisplayID) -> Void = { _ in }
    /// Called with the removed display's ID after a virtual display is destroyed (so the host can
    /// drop it from any selection).
    var onRemoved: (CGDirectDisplayID) -> Void = { _ in }

    @ObservedObject private var manager = VirtualDisplayManager.shared

    /// Lifetime policy. Off (default): a virtual display is torn down when removed from the grid or
    /// when record mode closes. On: virtual displays persist until the app quits.
    @AppStorage(AppConstants.captureKeepVirtualDisplaysAliveKey)
    private var keepAlive = AppConstants.defaultCaptureKeepVirtualDisplaysAlive

    /// Common pixel-perfect feed/recording resolutions.
    private static let presets: [(label: String, width: Int, height: Int)] = [
        ("720p · 1280×720", 1280, 720),
        ("1080p · 1920×1080", 1920, 1080),
        ("1440p · 2560×1440", 2560, 1440),
        ("4K UHD · 3840×2160", 3840, 2160),
    ]

    var body: some View {
        if VirtualDisplayManager.isSupported {
            Menu {
                Section("Add Virtual Display") {
                    ForEach(Self.presets, id: \.label) { preset in
                        Button(preset.label) {
                            addDisplay(width: preset.width, height: preset.height)
                        }
                    }
                }

                if !manager.activeDisplays.isEmpty {
                    Section("Remove Virtual Display") {
                        ForEach(manager.activeDisplays) { display in
                            Button("\(display.name)", role: .destructive) {
                                removeDisplay(display.id)
                            }
                        }
                    }
                }

                Divider()
                Section("Lifetime") {
                    Toggle("Keep Until App Quits", isOn: $keepAlive)
                        .help("On: virtual displays persist for the whole session. Off: each is removed when you take it off the grid or close record mode.")
                }
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isDisabled)
            .help("Create a virtual display to record a window off-screen")
        }
    }

    private func addDisplay(width: Int, height: Int) {
        Task {
            guard let id = await manager.create(width: width, height: height) else { return }
            await onDisplaysChanged()
            onCreated(id) // auto-select the new display for capture
        }
    }

    private func removeDisplay(_ id: CGDirectDisplayID) {
        Task {
            manager.destroy(id)
            await onDisplaysChanged()
            onRemoved(id)
        }
    }
}
