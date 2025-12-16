//
//  ConversionToolbarView.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct ConversionToolbarView: ToolbarContent {
    let isConverting: Bool
    let canStartConversion: Bool
    let hasFiles: Bool
    @Binding var watchFolderModeEnabled: Bool
    let watchFolderPath: String
    @Binding var selectedPreset: ExportPreset
    let presets: [ExportPreset]
    let displayName: (ExportPreset) -> String
    @Binding var mergeClipsEnabled: Bool
    let mergeClipsAvailable: Bool
    let onToggleConversion: () -> Void
    let onImport: () -> Void
    let onSelectOutputFolder: () -> Void
    let onResetAll: (_ optionKeyPressed: Bool) -> Void
    let hasResettableItems: Bool
    let onClear: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: onToggleConversion) {
                if isConverting {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "play.circle")
                        .foregroundStyle((!hasFiles || !canStartConversion) ? .gray : .green)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!hasFiles || (!canStartConversion && !isConverting))
            .help(hasFiles ? (isConverting ? "Cancel all conversions" : (canStartConversion ? "Start converting all files" : "No files ready to convert")) : "Add files to begin conversion")
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $mergeClipsEnabled) {
                Label("Merge Clips", systemImage: "play.square.stack.fill")
            }
            .toggleStyle(.button)
            .disabled(!mergeClipsAvailable)
            .help("Merge all files into one file. Only works if input files have the same settings (e.g. resolution, codec). Note that trimming becomes less accurate when merging clips.")
        }

        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $watchFolderModeEnabled) {
                Label("Watch Mode", systemImage: watchFolderModeEnabled ? "eye.fill" : "eye")
            }
            .toggleStyle(.button)
            .help(watchFolderPath.isEmpty ? "Select a watch folder to enable Watch Mode" : (watchFolderModeEnabled ? "Stop watching \(watchFolderPath)" : "Start watching \(watchFolderPath)"))
        }

        ToolbarItem(placement: .automatic) {
            Button(action: onImport) {
                Label("Import", systemImage: "plus.circle")
                    .foregroundColor(.accentColor)
            }
            .help("Import video files")
            .keyboardShortcut("i", modifiers: .command)
        }

        ToolbarItem(placement: .automatic) {
            Button(action: onSelectOutputFolder) {
                Label("Output", systemImage: "folder.badge.gearshape")
                    .foregroundColor(.accentColor)
            }
            .help("Select output folder")
            .keyboardShortcut("o", modifiers: .command)
        }

        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItem(placement: .automatic) {
            ResetButton(
                hasResettableItems: hasResettableItems,
                isConverting: isConverting,
                onReset: onResetAll
            )
        }

        ToolbarItem(placement: .automatic) {
            Button(action: onClear) {
                Label("Clear", systemImage: "square.stack.3d.up.slash")
                    .foregroundStyle((!hasFiles || isConverting) ? Color.gray : Color.red)
            }
            .help("Remove all files from the list")
            .disabled(!hasFiles || isConverting)
        }

        ToolbarItem(placement: .automatic) {
            Picker("Preset", selection: $selectedPreset) {
                ForEach(presets) { preset in
                    Text(displayName(preset)).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            .disabled(isConverting)
            .foregroundColor(.primary)
            .help("Select export preset for all files")
        }

        ToolbarItem {
            SettingsLink {
                Image(systemName: "gear")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Application Settings")
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Reset Button with Option Key Support

private struct ResetButton: View {
    let hasResettableItems: Bool
    let isConverting: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        ResetButtonNSViewWrapper(
            hasResettableItems: hasResettableItems,
            isConverting: isConverting,
            onReset: onReset
        )
    }
}

private struct ResetButtonNSViewWrapper: NSViewRepresentable {
    let hasResettableItems: Bool
    let isConverting: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Reset All")
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        let isEnabled = hasResettableItems && !isConverting
        nsView.isEnabled = isEnabled

        // Update appearance
        nsView.contentTintColor = isEnabled ? .systemBlue : .systemGray

        // Update tooltip based on settings
        let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
        if resetClearsSettings {
            nsView.toolTip = "Reset all items (clears trim, crop, audio routing). Hold Option to only reset status."
        } else {
            nsView.toolTip = "Reset all items to waiting status. Hold Option to also clear trim, crop, and audio routing."
        }

        context.coordinator.onReset = onReset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReset: onReset)
    }

    class Coordinator: NSObject {
        var onReset: (_ optionKeyPressed: Bool) -> Void

        init(onReset: @escaping (_ optionKeyPressed: Bool) -> Void) {
            self.onReset = onReset
        }

        @objc func buttonClicked(_ sender: NSButton) {
            let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
            onReset(optionKeyPressed)
        }
    }
}
