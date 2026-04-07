// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: String, Hashable {
        case general
        case metadata
        case presets
        case screenCapture
        case waveform
        case watchFolder
        case ytdlp
        case upload
        case whisper
        case ocr
        case analytics
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

            ScreenCaptureSettingsView()
                .tabItem { Label("Screen Capture", systemImage: "record.circle") }
                .tag(SettingsTab.screenCapture)

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

            WhisperSettingsView()
                .tabItem { Label("Transcription", systemImage: "captions.bubble") }
                .tag(SettingsTab.whisper)

            TesseractSettingsView()
                .tabItem { Label("OCR", systemImage: "character.magnify") }
                .tag(SettingsTab.ocr)

            AnalyticsSettingsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }
                .tag(SettingsTab.analytics)

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
            // Keyboard shortcuts for tab switching (Control+1-9, 0 to avoid conflict with main window's CMD+1-9, 0 preset selection)
            VStack(spacing: 0) {
                Button("") { selectedTab = .general }
                    .keyboardShortcut("1", modifiers: .control)
                Button("") { selectedTab = .metadata }
                    .keyboardShortcut("2", modifiers: .control)
                Button("") { selectedTab = .presets }
                    .keyboardShortcut("3", modifiers: .control)
                Button("") { selectedTab = .screenCapture }
                    .keyboardShortcut("4", modifiers: .control)
                Button("") { selectedTab = .waveform }
                    .keyboardShortcut("5", modifiers: .control)
                Button("") { selectedTab = .watchFolder }
                    .keyboardShortcut("6", modifiers: .control)
                Button("") { selectedTab = .ytdlp }
                    .keyboardShortcut("7", modifiers: .control)
                Button("") { selectedTab = .upload }
                    .keyboardShortcut("8", modifiers: .control)
                Button("") { selectedTab = .whisper }
                    .keyboardShortcut("9", modifiers: .control)
                Button("") { selectedTab = .analytics }
                    .keyboardShortcut("0", modifiers: .control)
                Button("") { selectedTab = .updates }
                    .keyboardShortcut("a", modifiers: .control)
                Button("") { selectedTab = .shortcuts }
                    .keyboardShortcut("k", modifiers: .control)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .onAppear {
            // Check if we should open to a specific tab (e.g., from Control+K in main window)
            if let tabToOpen = UserDefaults.standard.string(forKey: AppConstants.settingsTabToOpenKey) {
                if let tab = SettingsTab(rawValue: tabToOpen) {
                    selectedTab = tab
                }
                // Clear the key so subsequent opens go to the default tab
                UserDefaults.standard.removeObject(forKey: AppConstants.settingsTabToOpenKey)
            }
        }
    }
}

#Preview {
    SettingsView()
}
