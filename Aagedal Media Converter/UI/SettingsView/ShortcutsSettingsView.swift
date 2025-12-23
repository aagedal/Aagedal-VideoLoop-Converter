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
                // Main Window Shortcuts
                ShortcutSection(title: "Main Window", shortcuts: [
                    ShortcutItem(keys: "Cmd + Return", description: "Start/Stop conversion"),
                    ShortcutItem(keys: "Cmd + I", description: "Import files"),
                    ShortcutItem(keys: "Cmd + O", description: "Select output folder"),
                    ShortcutItem(keys: "Cmd + Backspace", description: "Delete selected items"),
                    ShortcutItem(keys: "Cmd + R", description: "Reset selected items"),
                    ShortcutItem(keys: "Cmd + Shift + R", description: "Reset all items"),
                    ShortcutItem(keys: "Option + D", description: "Deselect all items"),
                    ShortcutItem(keys: "Cmd + Up Arrow", description: "Move selection up in queue"),
                    ShortcutItem(keys: "Cmd + Down Arrow", description: "Move selection down in queue"),
                    ShortcutItem(keys: "Ctrl + S", description: "Sort queue (cycles: Name A→Z, Z→A, Date Old→New, New→Old)"),
                    ShortcutItem(keys: "Ctrl + M", description: "Toggle mute on selected items"),
                    ShortcutItem(keys: "Tab", description: "Focus next comment field"),
                    ShortcutItem(keys: "Shift + Tab", description: "Focus previous comment field"),
                ])
                
                // Single Selection Shortcuts
                ShortcutSection(title: "Single Selection (Main Window)", shortcuts: [
                    ShortcutItem(keys: "Cmd + T", description: "Open Trim/Preview editor"),
                    ShortcutItem(keys: "Option + C", description: "Open Crop mode"),
                    ShortcutItem(keys: "Option + I", description: "Open Metadata Info"),
                    ShortcutItem(keys: "Option + T", description: "Open Timecode configuration"),
                    ShortcutItem(keys: "Option + A", description: "Open Audio Routing configuration"),
                    ShortcutItem(keys: "Cmd + D", description: "Toggle date tag"),
                    ShortcutItem(keys: "Cmd + F", description: "Open fullscreen player"),
                ])
                
                // Global Shortcuts
                ShortcutSection(title: "Global Shortcuts", shortcuts: [
                    ShortcutItem(keys: "Option + W", description: "Toggle Watch Folder mode"),
                    ShortcutItem(keys: "Option + F", description: "Select output folder"),
                    ShortcutItem(keys: "Option + M", description: "Toggle Merge clips"),
                    ShortcutItem(keys: "Cmd + ,", description: "Open Settings"),
                ])
                
                Divider()
                    .padding(.vertical, 8)
                
                // Trim/Preview View Shortcuts
                ShortcutSection(title: "Trim/Preview Editor", shortcuts: [
                    ShortcutItem(keys: "Space", description: "Toggle playback (play/pause)"),
                    ShortcutItem(keys: "I", description: "Set trim in-point"),
                    ShortcutItem(keys: "O", description: "Set trim out-point"),
                    ShortcutItem(keys: "Option + I", description: "Clear trim start (reset to beginning)"),
                    ShortcutItem(keys: "Option + O", description: "Clear trim end (reset to end)"),
                    ShortcutItem(keys: "Shift + I", description: "Jump to trim in-point"),
                    ShortcutItem(keys: "Shift + O", description: "Jump to trim out-point"),
                    ShortcutItem(keys: "Left Arrow", description: "Step backward 1 frame"),
                    ShortcutItem(keys: "Right Arrow", description: "Step forward 1 frame"),
                    ShortcutItem(keys: "Up Arrow", description: "Jump backward 10 frames"),
                    ShortcutItem(keys: "Down Arrow", description: "Jump forward 10 frames"),
                    ShortcutItem(keys: "J", description: "Reverse playback"),
                    ShortcutItem(keys: "K", description: "Toggle playback"),
                    ShortcutItem(keys: "L", description: "Fast forward"),
                    ShortcutItem(keys: "C", description: "Toggle crop controls"),
                    ShortcutItem(keys: "T", description: "Toggle timecode display mode"),
                    ShortcutItem(keys: "Cmd + L", description: "Toggle loop playback"),
                    ShortcutItem(keys: "Cmd + A", description: "Toggle audio meter"),
                    ShortcutItem(keys: "Cmd + S", description: "Capture screenshot"),
                    ShortcutItem(keys: "Cmd + F", description: "Toggle fullscreen"),
                    ShortcutItem(keys: "0-9, +, -, ., :, ;", description: "Activate timecode input"),
                    ShortcutItem(keys: "Escape", description: "Close editor"),
                ])

                // Crop Mode Shortcuts
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

                // Timeline Modifier Gestures
                ShortcutSection(title: "Timeline Gestures (hold while dragging)", shortcuts: [
                    ShortcutItem(keys: "Cmd", description: "Range selection: click and drag to set in/out points"),
                    ShortcutItem(keys: "Shift", description: "Range sliding: drag to move entire trim range"),
                    ShortcutItem(keys: "Option", description: "Symmetric scaling: drag handle to move both symmetrically"),
                ])
                
                // Timecode Configuration Shortcuts
                ShortcutSection(title: "Timecode Configuration", shortcuts: [
                    ShortcutItem(keys: "Cmd + 1", description: "Select 'Preserve Source' mode"),
                    ShortcutItem(keys: "Cmd + 2", description: "Select 'Manual Override' mode"),
                    ShortcutItem(keys: "Cmd + 3", description: "Select 'Disable' mode"),
                    ShortcutItem(keys: "0-9", description: "Switch to manual mode and start typing"),
                    ShortcutItem(keys: "Escape", description: "Close timecode configuration"),
                ])

                // Audio Routing Shortcuts
                ShortcutSection(title: "Audio Routing", shortcuts: [
                    ShortcutItem(keys: "Cmd + 1-8", description: "Toggle source audio track 1-8 in/out of output"),
                    ShortcutItem(keys: "Ctrl + M", description: "Toggle mute audio"),
                    ShortcutItem(keys: "Escape", description: "Close audio routing"),
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
