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
    /// The capture target binding (0 = Automatic/Main, else a CGDirectDisplayID).
    @Binding var captureDisplayID: Int
    /// Disable while a recording/processing is in flight.
    var isDisabled: Bool = false
    /// Re-fetch the host's available-displays list after a create/destroy so the
    /// new display shows up (or a removed one disappears) in the picker.
    var onDisplaysChanged: () async -> Void

    @ObservedObject private var manager = VirtualDisplayManager.shared

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
            captureDisplayID = Int(id) // auto-select the new display for capture
        }
    }

    private func removeDisplay(_ id: CGDirectDisplayID) {
        Task {
            let wasSelected = captureDisplayID == Int(id)
            manager.destroy(id)
            await onDisplaysChanged()
            if wasSelected { captureDisplayID = 0 }
        }
    }
}
