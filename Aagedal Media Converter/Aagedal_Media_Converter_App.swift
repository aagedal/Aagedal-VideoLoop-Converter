// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import SwiftData
import AppKit
import OSLog
import Combine
import Sparkle

@main
struct Aagedal_Media_Converter_App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Construct Sparkle eagerly so the updater attaches to the run loop
    /// before the first window appears. Inert for Homebrew installs and when
    /// SUFeedURL is unset — see `SparkleUpdater.isActive`.
    private let sparkleUpdater = SparkleUpdater.shared

    init() {
        // Suppress MoltenVK info logs (level 2 = warnings only, no info spam)
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1)

        // Show tooltips instantly (default is ~1s delay)
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])

        UserDefaults.standard.register(defaults: [
            AppConstants.watchFolderIgnoreOlderThan24hKey: false,
            AppConstants.watchFolderAutoDeleteOlderThanWeekKey: false,
            AppConstants.watchFolderIgnoreDurationValueKey: AppConstants.defaultWatchFolderIgnoreDurationValue,
            AppConstants.watchFolderIgnoreDurationUnitKey: AppConstants.defaultWatchFolderIgnoreDurationUnitRaw,
            AppConstants.watchFolderDeleteDurationValueKey: AppConstants.defaultWatchFolderDeleteDurationValue,
            AppConstants.watchFolderDeleteDurationUnitKey: AppConstants.defaultWatchFolderDeleteDurationUnitRaw,
            AppConstants.previewCacheCleanupPolicyKey: AppConstants.defaultPreviewCacheCleanupPolicyRaw,
            AppConstants.audioWaveformVideoDefaultEnabledKey: true,
            AppConstants.audioWaveformResolutionKey: "1280x720",
            AppConstants.audioWaveformBackgroundColorKey: "#000000",
            AppConstants.audioWaveformForegroundColorKey: "#FFFFFF",
            AppConstants.audioWaveformNormalizeKey: false,
            AppConstants.audioWaveformStyleKey: AppConstants.defaultAudioWaveformStyleRaw,
            AppConstants.audioWaveformLineThicknessKey: AppConstants.defaultAudioWaveformLineThickness,
            AppConstants.audioWaveformDetailLevelKey: AppConstants.defaultAudioWaveformDetailLevel,
            AppConstants.captureDisplayIDKey: 0,
            AppConstants.captureHideCursorKey: AppConstants.defaultCaptureHideCursor,
            AppConstants.captureExcludeCurrentAppKey: AppConstants.defaultCaptureExcludeCurrentApp,
            AppConstants.captureFrameRateKey: AppConstants.defaultCaptureFrameRate,
            AppConstants.captureDynamicRangeKey: AppConstants.defaultCaptureDynamicRange,
            AppConstants.captureIncludeMicrophoneKey: AppConstants.defaultCaptureIncludeMicrophone,
            AppConstants.captureMicrophoneDeviceIDKey: AppConstants.defaultCaptureMicrophoneDeviceID,
            AppConstants.autoDeleteOldEncodesKey: AppConstants.defaultAutoDeleteOldEncodes,
            AppConstants.autoDeleteOldEncodesDaysKey: AppConstants.defaultAutoDeleteOldEncodesDays
        ])

        Self.migrateAudioPresets()
        UploadProfileStore.migrateLegacyProfilesIfNeeded()
        applyPreviewCacheCleanupPolicy()
        TesseractService.purgeOrphanTempDirs()
        OutputFolderCleanupService.shared.start()
        // Bring the settings-sync singleton (and its file/UserDefaults observers)
        // online at launch so a snapshot that arrived while closed is pulled in.
        SettingsSyncService.shared.activate()
    }

    /// One-time migration: consolidate 3 audio presets into unified Audio Only preset
    private static func migrateAudioPresets() {
        let defaults = UserDefaults.standard
        let migrationKey = "audioPresetMigrationV1"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // Migrate default preset selection
        if let currentDefault = defaults.string(forKey: AppConstants.defaultPresetKey) {
            switch currentDefault {
            case "Audio only WAV (all channels)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                defaults.set(AudioOnlyFormat.wav.rawValue, forKey: AppConstants.audioOnlyFormatKey)
            case "Audio only AAC (stereo downmix)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                defaults.set(AudioOnlyFormat.aac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
            case "Audio only MP4 (all tracks)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                defaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
            default:
                break
            }
        }

        // Migrate visibility: visible if any of the three old presets was visible
        let wavVisible = defaults.object(forKey: AppConstants.audioWAVVisibleKey) as? Bool ?? true
        let aacVisible = defaults.object(forKey: AppConstants.audioAACVisibleKey) as? Bool ?? true
        let mp4Visible = defaults.object(forKey: AppConstants.audioMP4VisibleKey) as? Bool ?? true
        defaults.set(wavVisible || aacVisible || mp4Visible, forKey: AppConstants.audioOnlyVisibleKey)

        defaults.set(true, forKey: migrationKey)
    }

    var body: some Scene {
        WindowGroup {
            VStack {
                ContentView()
            }
        }
        .handlesExternalEvents(matching: []) // Prevent automatic window creation for opened files
        .windowStyle(.automatic)
        .windowToolbarStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            MainAppCommands(sparkleUpdater: sparkleUpdater)
        }
        Settings {
            SettingsView().keyboardShortcut(",",modifiers: .command)
        }
        Window("About Aagedal Media Converter", id: "about") {
            AboutView()
        }
        .handlesExternalEvents(matching: ["about"])
        .windowResizability(.contentSize)
    }
}

struct MainAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let sparkleUpdater: SparkleUpdater

    var body: some Commands {
        // Disable "New Window" — replaced by "New Encoding Group"
        CommandGroup(replacing: .newItem) {
            Button("New Encoding Group") {
                NotificationCenter.default.post(name: .createEncodingGroup, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // "Check for Updates…" for direct-download installs. Hidden for
        // Homebrew installs — those users get the brew-upgrade hint instead.
        if sparkleUpdater.isActive {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    sparkleUpdater.controller.checkForUpdates(nil)
                }
            }
        }

        CommandGroup(after: .importExport) {
            Button("Import…") {
                NotificationCenter.default.post(name: .showFileImporter, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Import Camera Card…") {
                NotificationCenter.default.post(name: .showCameraCardImporter, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            Button("Export Settings…") {
                NotificationCenter.default.post(name: .exportSettingsRequested, object: nil)
            }
            Button("Import Settings…") {
                NotificationCenter.default.post(name: .importSettingsRequested, object: nil)
            }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Metadata") {
                MetadataWindowController.shared.showWindow()
            }
            .keyboardShortcut("i", modifiers: .option)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Aagedal Media Converter") {
                openWindow(id: "about")
            }
        }
    }
}

private extension Aagedal_Media_Converter_App {
    func applyPreviewCacheCleanupPolicy() {
        let defaults = UserDefaults.standard
        let storedPolicyRaw = defaults.string(forKey: AppConstants.previewCacheCleanupPolicyKey) ?? AppConstants.defaultPreviewCacheCleanupPolicyRaw
        let policy = PreviewCacheCleanupPolicy(rawValue: storedPolicyRaw) ?? .purgeOnLaunch

        Task {
            await PreviewAssetGenerator.shared.applyCleanupPolicy(policy)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var isFirstActivation = true
    private var statusItemController: RecordingStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            statusItemController = RecordingStatusItemController(
                captureManager: ScreenCaptureManager.shared
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Terminate any running FFmpeg/FFprobe processes spawned by preview asset generation
        // This prevents orphaned processes when the app closes
        PreviewAssetGenerator.shared.terminateAllProcessesSync()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Ignore the first activation (app launch) to avoid conflict with default SwiftUI window creation
        if isFirstActivation {
            isFirstActivation = false
            return
        }

        // Don't create a main window while the capture overlay is active
        Task { @MainActor in
            guard !CaptureOverlayWindowController.shared.isShowing else { return }
            let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
            if visibleWindows.isEmpty {
                ensureMainWindowIsVisible()
            }
        }
    }
    
    // MARK: - Handle files dropped on dock icon
    func application(_ application: NSApplication, open urls: [URL]) {
        // Filter for supported video files only
        let videoURLs = urls.filter { VideoFileUtils.isVideoFile(url: $0) }
        
        guard !videoURLs.isEmpty else { return }
        
        // Check if there are any visible windows
        let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        
        if visibleWindows.isEmpty {
            // No windows open - let SwiftUI create a new window and add files there
            Task { @MainActor in
                ensureMainWindowIsVisible()
            }
            // We need to delay posting notifications until the new window is created
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for url in videoURLs {
                    NotificationCenter.default.post(name: .enqueueFileURL, object: url)
                }
            }
        } else {
            // Windows exist - bring the frontmost one forward and add files there
            if let frontWindow = visibleWindows.first {
                frontWindow.makeKeyAndOrderFront(nil)
            }
            
            // Post notifications for the existing window(s)
            for url in videoURLs {
                NotificationCenter.default.post(name: .enqueueFileURL, object: url)
            }
        }
    }

    @MainActor
    private func ensureMainWindowIsVisible() {
        let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        guard visibleWindows.isEmpty else { return }
        openNewMainWindow()
    }

    @MainActor
    private func openNewMainWindow() {
        guard let menuItem = findNewWindowMenuItem(), let action = menuItem.action else { return }
        // IMPORTANT: Pass 'menuItem' as sender so SwiftUI knows which command to trigger
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    @MainActor
    private func findNewWindowMenuItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            for subitem in submenu.items {
                if subitem.keyEquivalent == "n" && subitem.keyEquivalentModifierMask.contains(.command) {
                    return subitem
                }
            }
        }
        return nil
    }
}

@MainActor
private final class RecordingStatusItemController: NSObject {
    private let captureManager: ScreenCaptureManager
    private var statusItem: NSStatusItem
    private var recordingCancellable: AnyCancellable?

    init(captureManager: ScreenCaptureManager) {
        self.captureManager = captureManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        recordingCancellable = captureManager.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.updateStatusItem(isRecording: isRecording)
            }
    }

    private func updateStatusItem(isRecording: Bool) {
        statusItem.isVisible = isRecording
        if isRecording {
            configureStatusItem()
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Stop Recording")
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemRed
            button.target = self
            button.action = #selector(stopRecording)
            button.toolTip = "Stop Screen Recording"
        }
    }

    @objc private func stopRecording() {
        Task {
            await captureManager.stopRecording()
        }
    }
}

