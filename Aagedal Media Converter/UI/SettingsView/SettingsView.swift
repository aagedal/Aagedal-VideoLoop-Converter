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
            
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.updates)
            
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
        }
        .frame(width: 600, height: 560)
        .navigationTitle("Settings – Aagedal Media Converter")
        .padding(.horizontal, 20)
    }
}

#Preview {
    SettingsView()
}
