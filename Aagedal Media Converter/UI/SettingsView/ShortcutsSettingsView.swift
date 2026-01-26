// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Main Window
                Text("Main Window")
                    .font(.title2)
                    .fontWeight(.bold)

                ShortcutSection(title: "File Operations", shortcuts: [
                    ShortcutItem(keys: "Cmd + I", description: "Open import dialogue"),
                    ShortcutItem(keys: "Cmd + D", description: "Show URL input overlay (for downloading)"),
                    ShortcutItem(keys: "Cmd + P", description: "Open preset quick-select overlay"),
                    ShortcutItem(keys: "Option + F", description: "Select output folder"),
                    ShortcutItem(keys: "Option + W", description: "Toggle watch folder"),
                ])

                ShortcutSection(title: "Conversion", shortcuts: [
                    ShortcutItem(keys: "Cmd + Return", description: "Start/Stop encoding"),
                    ShortcutItem(keys: "Option + M", description: "Toggle merging of clips"),
                    ShortcutItem(keys: "Cmd + 1-9, 0", description: "Instantly select preset (0 = 10th)"),
                ])

                ShortcutSection(title: "Queue Navigation", shortcuts: [
                    ShortcutItem(keys: "Tab", description: "Select comment field of first clip, or cycle to next"),
                    ShortcutItem(keys: "Shift + Tab", description: "Select comment field of last clip, or cycle to previous"),
                    ShortcutItem(keys: "Up Arrow", description: "Move selection up"),
                    ShortcutItem(keys: "Down Arrow", description: "Move selection down"),
                    ShortcutItem(keys: "Cmd + Up Arrow", description: "Move selected item(s) up in queue"),
                    ShortcutItem(keys: "Cmd + Down Arrow", description: "Move selected item(s) down in queue"),
                    ShortcutItem(keys: "Option + D", description: "Deselect all items"),
                    ShortcutItem(keys: "Ctrl + S", description: "Cycle through sort modes"),
                ])

                ShortcutSection(title: "Item Management", shortcuts: [
                    ShortcutItem(keys: "Cmd + Backspace", description: "Remove selected items from queue"),
                    ShortcutItem(keys: "Cmd + R", description: "Reset conversion status of selected items"),
                    ShortcutItem(keys: "Cmd + Shift + R", description: "Reset conversion status of all items"),
                    ShortcutItem(keys: "Ctrl + D", description: "Toggle metadata date tag on selected items"),
                    ShortcutItem(keys: "Ctrl + M", description: "Toggle mute on selected items"),
                    ShortcutItem(keys: "Cmd + U", description: "Toggle upload on selected items"),
                    ShortcutItem(keys: "Cmd + Option + U", description: "Toggle source file upload on selected items"),
                    ShortcutItem(keys: "Cmd + E", description: "Toggle auto-encode on selected items"),
                ])

                ShortcutSection(title: "Other", shortcuts: [
                    ShortcutItem(keys: "Cmd + ,", description: "Open Settings"),
                    ShortcutItem(keys: "Cmd + Shift + C", description: "Open Capture Mode"),
                    ShortcutItem(keys: "Ctrl + R", description: "Show new random tip"),
                    ShortcutItem(keys: "Ctrl + K", description: "Open Shortcuts help"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Single Item Selected
                ShortcutSection(title: "Single Item Selected in Main Window", shortcuts: [
                    ShortcutItem(keys: "Cmd + T", description: "Open trim view"),
                    ShortcutItem(keys: "Cmd + F", description: "Open fullscreen player"),
                    ShortcutItem(keys: "Option + T", description: "Open Timecode override view"),
                    ShortcutItem(keys: "Option + A", description: "Open Audio Routing view"),
                    ShortcutItem(keys: "Option + I", description: "Open metadata view"),
                    ShortcutItem(keys: "Option + C", description: "Open Crop mode"),
                    ShortcutItem(keys: "Cmd + Option + T", description: "Toggle transcription on selected items"),
                    ShortcutItem(keys: "Tab", description: "Activate focus on the comment field"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Trim View
                Text("Trim View")
                    .font(.title2)
                    .fontWeight(.bold)

                ShortcutSection(title: "Playback", shortcuts: [
                    ShortcutItem(keys: "Space", description: "Toggle play/pause"),
                    ShortcutItem(keys: "J", description: "Play backwards"),
                    ShortcutItem(keys: "K", description: "Play/pause"),
                    ShortcutItem(keys: "L", description: "Play forwards"),
                    ShortcutItem(keys: "Cmd + L", description: "Toggle loop mode"),
                ])

                ShortcutSection(title: "Navigation", shortcuts: [
                    ShortcutItem(keys: "Left Arrow", description: "Go to previous frame"),
                    ShortcutItem(keys: "Right Arrow", description: "Go to next frame"),
                    ShortcutItem(keys: "I", description: "Set in point"),
                    ShortcutItem(keys: "O", description: "Set out point"),
                    ShortcutItem(keys: "Option + I", description: "Clear trim start (reset to beginning)"),
                    ShortcutItem(keys: "Option + O", description: "Clear trim end (reset to end)"),
                    ShortcutItem(keys: "Shift + I", description: "Jump to trim in-point"),
                    ShortcutItem(keys: "Shift + O", description: "Jump to trim out-point"),
                ])

                ShortcutSection(title: "Timecode Input", shortcuts: [
                    ShortcutItem(keys: "+/-", description: "Jump seconds back/forward when pressing Enter"),
                    ShortcutItem(keys: "0-9", description: "Activate timecode input, press Enter to jump"),
                    ShortcutItem(keys: "Full timecode", description: "hours:minutes:seconds:frames supported"),
                ])

                ShortcutSection(title: "Tools", shortcuts: [
                    ShortcutItem(keys: "C", description: "Enter crop tool"),
                    ShortcutItem(keys: "T", description: "Toggle timecode display mode"),
                    ShortcutItem(keys: "Cmd + A", description: "Toggle audio meter"),
                    ShortcutItem(keys: "Cmd + S", description: "Capture screenshot"),
                    ShortcutItem(keys: "Cmd + F", description: "Toggle fullscreen"),
                    ShortcutItem(keys: "Escape", description: "Close editor"),
                ])

                ShortcutSection(title: "Timeline Modifiers (hold while dragging)", shortcuts: [
                    ShortcutItem(keys: "Cmd", description: "Range selection: click and drag to set in/out points"),
                    ShortcutItem(keys: "Shift", description: "Range sliding: drag to move entire trim range"),
                    ShortcutItem(keys: "Option", description: "Symmetric scaling: drag handle to move both symmetrically"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Fullscreen Player
                Text("Fullscreen Player")
                    .font(.title2)
                    .fontWeight(.bold)

                ShortcutSection(title: "Playback", shortcuts: [
                    ShortcutItem(keys: "Space", description: "Toggle playback"),
                    ShortcutItem(keys: "J", description: "Start reverse playback"),
                    ShortcutItem(keys: "K", description: "Toggle playback"),
                    ShortcutItem(keys: "L", description: "Fast forward"),
                ])

                ShortcutSection(title: "Navigation", shortcuts: [
                    ShortcutItem(keys: "Left Arrow", description: "Seek back 1 frame"),
                    ShortcutItem(keys: "Right Arrow", description: "Seek forward 1 frame"),
                    ShortcutItem(keys: "Up Arrow", description: "Seek back 10 frames"),
                    ShortcutItem(keys: "Down Arrow", description: "Seek forward 10 frames"),
                    ShortcutItem(keys: "Cmd + B", description: "Go to previous item in queue"),
                    ShortcutItem(keys: "Cmd + N", description: "Go to next item in queue"),
                ])

                ShortcutSection(title: "Other", shortcuts: [
                    ShortcutItem(keys: "A", description: "Toggle Auto Next mode"),
                    ShortcutItem(keys: "Cmd + L", description: "Toggle Loop Queue (requires Auto Next)"),
                    ShortcutItem(keys: "T", description: "Toggle timecode mode"),
                    ShortcutItem(keys: "0-9, +, -, ., :, ;", description: "Activate timecode input"),
                    ShortcutItem(keys: "Cmd + S", description: "Capture screenshot"),
                    ShortcutItem(keys: "Escape", description: "Close fullscreen player"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Audio Routing View
                ShortcutSection(title: "Audio Routing View", shortcuts: [
                    ShortcutItem(keys: "Ctrl + M", description: "Toggle mute audio"),
                    ShortcutItem(keys: "Cmd + 1-8", description: "Toggle individual audio track (1-8)"),
                    ShortcutItem(keys: "Cmd + Option + 1-9", description: "Toggle stereo for output track position"),
                    ShortcutItem(keys: "Cmd + Option + S", description: "Toggle stereo for all surround tracks"),
                    ShortcutItem(keys: "Escape", description: "Close audio routing"),
                ])

                // MARK: - Timecode Configuration View
                ShortcutSection(title: "Timecode Configuration View", shortcuts: [
                    ShortcutItem(keys: "Cmd + 1", description: "Switch to Preserve Source mode"),
                    ShortcutItem(keys: "Cmd + 2", description: "Switch to Manual mode"),
                    ShortcutItem(keys: "Cmd + 3", description: "Switch to Disabled mode"),
                    ShortcutItem(keys: "0-9", description: "Start typing in manual mode"),
                    ShortcutItem(keys: "Escape", description: "Close timecode configuration"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Settings Window
                ShortcutSection(title: "Settings Window", shortcuts: [
                    ShortcutItem(keys: "Ctrl + 1", description: "General"),
                    ShortcutItem(keys: "Ctrl + 2", description: "Metadata"),
                    ShortcutItem(keys: "Ctrl + 3", description: "Presets"),
                    ShortcutItem(keys: "Ctrl + 4", description: "Screen Capture"),
                    ShortcutItem(keys: "Ctrl + 5", description: "Waveform"),
                    ShortcutItem(keys: "Ctrl + 6", description: "Watch Folder"),
                    ShortcutItem(keys: "Ctrl + 7", description: "Downloads"),
                    ShortcutItem(keys: "Ctrl + 8", description: "Upload"),
                    ShortcutItem(keys: "Ctrl + 9", description: "Transcription"),
                    ShortcutItem(keys: "Ctrl + 0", description: "Updates"),
                    ShortcutItem(keys: "Ctrl + K", description: "Shortcuts (also works from main window)"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Overlays
                ShortcutSection(title: "Any Overlay View", shortcuts: [
                    ShortcutItem(keys: "Escape", description: "Close the overlay (settings automatically saved)"),
                ])

                ShortcutSection(title: "URL Input Overlay", shortcuts: [
                    ShortcutItem(keys: "Down Arrow", description: "Navigate into download history (older entries)"),
                    ShortcutItem(keys: "Up Arrow", description: "Navigate back (newer entries or original text)"),
                    ShortcutItem(keys: "Return", description: "Submit URL and start download"),
                    ShortcutItem(keys: "Escape", description: "Close URL input overlay"),
                ])

                ShortcutSection(title: "Preset Quick-Select Overlay", shortcuts: [
                    ShortcutItem(keys: "Up Arrow", description: "Navigate through presets"),
                    ShortcutItem(keys: "Down Arrow", description: "Navigate through presets"),
                    ShortcutItem(keys: "Return", description: "Confirm selection"),
                    ShortcutItem(keys: "Cmd + 1-9, 0", description: "Instantly select preset (0 = 10th)"),
                    ShortcutItem(keys: "Escape", description: "Close without changing"),
                ])

                ShortcutSection(title: "Capture Mode", shortcuts: [
                    ShortcutItem(keys: "Escape", description: "Close/Cancel capture mode"),
                    ShortcutItem(keys: "Cmd + .", description: "Close/Cancel capture mode"),
                ])

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Crop Mode
                ShortcutSection(title: "Crop Mode", shortcuts: [
                    ShortcutItem(keys: "Cmd + 1", description: "Free aspect ratio"),
                    ShortcutItem(keys: "Cmd + 2", description: "21:9 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 3", description: "16:9 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 4", description: "3:2 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 5", description: "4:3 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 6", description: "1:1 (Square) aspect ratio"),
                    ShortcutItem(keys: "Cmd + 7", description: "3:4 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 8", description: "2:3 aspect ratio"),
                    ShortcutItem(keys: "Cmd + 9", description: "9:16 (Vertical) aspect ratio"),
                    ShortcutItem(keys: "Cmd + 0", description: "Reset crop"),
                    ShortcutItem(keys: "Cmd + +", description: "Scale crop box larger"),
                    ShortcutItem(keys: "Cmd + -", description: "Scale crop box smaller"),
                ])

            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Helper Views

private struct ShortcutSection: View {
    let title: String
    let shortcuts: [ShortcutItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            VStack(spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            }
        }
    }
}

private struct ShortcutItem: Identifiable {
    let id = UUID()
    let keys: String
    let description: String
}

private struct ShortcutRow: View {
    let shortcut: ShortcutItem

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            KeyboardShortcutBadge(keys: shortcut.keys)
                .frame(width: 180, alignment: .leading)

            Text(shortcut.description)
                .font(.body)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

private struct KeyboardShortcutBadge: View {
    let keys: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(parseKeys(keys), id: \.self) { key in
                KeyCap(key: key)
            }
        }
    }

    private func parseKeys(_ keys: String) -> [String] {
        // Split by " + " to get individual keys
        keys.components(separatedBy: " + ")
    }
}

private struct KeyCap: View {
    let key: String

    var body: some View {
        Text(displayKey(key))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
    }

    private func displayKey(_ key: String) -> String {
        // Convert key names to symbols where appropriate
        switch key.lowercased() {
        case "cmd", "command":
            return "\u{2318}"
        case "option", "alt":
            return "\u{2325}"
        case "shift":
            return "\u{21E7}"
        case "control", "ctrl":
            return "\u{2303}"
        case "return", "enter":
            return "\u{21A9}"
        case "backspace", "delete":
            return "\u{232B}"
        case "escape", "esc":
            return "\u{238B}"
        case "tab":
            return "\u{21E5}"
        case "space":
            return "\u{2423}"
        case "up arrow":
            return "\u{2191}"
        case "down arrow":
            return "\u{2193}"
        case "left arrow":
            return "\u{2190}"
        case "right arrow":
            return "\u{2192}"
        default:
            return key
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 550, height: 600)
}
