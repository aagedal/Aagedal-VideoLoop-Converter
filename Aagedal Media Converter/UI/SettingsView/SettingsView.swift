// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: Hashable {
        case general
        case metadata
        case presets
        case waveform
        case watchFolder
        case ytdlp
        case upload
        case updates
        case shortcuts
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            MetadataSettingsView()
                .tabItem { Label("Metadata", systemImage: "info.circle") }
                .tag(SettingsTab.metadata)

            PresetsSettingsView()
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.presets)

            WaveformSettingsView()
                .tabItem { Label("Audio Waveform", systemImage: "waveform") }
                .tag(SettingsTab.waveform)

            WatchFolderSettingsView()
                .tabItem { Label("Watch Folder", systemImage: "eye.fill") }
                .tag(SettingsTab.watchFolder)

            YTDLPSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.ytdlp)

            UploadSettingsView()
                .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
                .tag(SettingsTab.upload)

            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.updates)

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
        }
        .frame(width: 760, height: 600)
        .navigationTitle("Settings – Aagedal Media Converter")
        .padding(.horizontal, 20)
        .background {
            // Keyboard shortcuts for tab switching
            VStack(spacing: 0) {
                Button("") { selectedTab = .general }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .metadata }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .presets }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .waveform }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { selectedTab = .watchFolder }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { selectedTab = .ytdlp }
                    .keyboardShortcut("6", modifiers: .command)
                Button("") { selectedTab = .upload }
                    .keyboardShortcut("7", modifiers: .command)
                Button("") { selectedTab = .updates }
                    .keyboardShortcut("8", modifiers: .command)
                Button("") { selectedTab = .shortcuts }
                    .keyboardShortcut("9", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }
}

#Preview {
    SettingsView()
}
