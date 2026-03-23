// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// Manages preset selection, visibility, and custom preset naming.
/// Extracted from ContentView to reduce complexity and centralize preset logic.
@MainActor
@Observable
final class PresetManager {
    static let shared = PresetManager()

    // MARK: - Current Selection State

    var selectedPreset: ExportPreset = .videoLoop
    var hasUserChangedPreset: Bool = false

    // MARK: - Custom Preset Names (synced with UserDefaults)

    private var customPreset1Name: String
    private var customPreset2Name: String
    private var customPreset3Name: String
    private var customPreset4Name: String
    private var customPreset5Name: String
    private var customPreset6Name: String
    private var customPreset7Name: String
    private var customPreset8Name: String
    private var customPreset9Name: String
    private var customPreset10Name: String

    // MARK: - Built-in Preset Visibility

    private var videoLoopVisible: Bool
    private var videoLoopWithSoundVisible: Bool
    private var animatedStillVisible: Bool
    private var h264Visible: Bool
    private var h265Visible: Bool
    private var av1Visible: Bool
    private var tvHEVCVisible: Bool
    private var tvAVCIntraVisible: Bool
    private var proresVisible: Bool
    private var proxyVisible: Bool
    private var streamCopyVisible: Bool
    private var audioWAVVisible: Bool
    private var audioAACVisible: Bool
    private var imageSequenceVisible: Bool
    private var dcpVisible: Bool

    // MARK: - Custom Preset Activation

    private var customPreset1Active: Bool
    private var customPreset2Active: Bool
    private var customPreset3Active: Bool
    private var customPreset4Active: Bool
    private var customPreset5Active: Bool
    private var customPreset6Active: Bool
    private var customPreset7Active: Bool
    private var customPreset8Active: Bool
    private var customPreset9Active: Bool
    private var customPreset10Active: Bool

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard

        // Load custom preset names
        customPreset1Name = defaults.string(forKey: AppConstants.customPreset1NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[0]
        customPreset2Name = defaults.string(forKey: AppConstants.customPreset2NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[1]
        customPreset3Name = defaults.string(forKey: AppConstants.customPreset3NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[2]
        customPreset4Name = defaults.string(forKey: AppConstants.customPreset4NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[3]
        customPreset5Name = defaults.string(forKey: AppConstants.customPreset5NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[4]
        customPreset6Name = defaults.string(forKey: AppConstants.customPreset6NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[5]
        customPreset7Name = defaults.string(forKey: AppConstants.customPreset7NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[6]
        customPreset8Name = defaults.string(forKey: AppConstants.customPreset8NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[7]
        customPreset9Name = defaults.string(forKey: AppConstants.customPreset9NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[8]
        customPreset10Name = defaults.string(forKey: AppConstants.customPreset10NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[9]

        // Load built-in preset visibility (default to true if not set)
        videoLoopVisible = defaults.object(forKey: AppConstants.videoLoopVisibleKey) as? Bool ?? true
        videoLoopWithSoundVisible = defaults.object(forKey: AppConstants.videoLoopWithSoundVisibleKey) as? Bool ?? true
        animatedStillVisible = defaults.object(forKey: AppConstants.animatedStillVisibleKey) as? Bool ?? true
        h264Visible = defaults.object(forKey: AppConstants.h264VisibleKey) as? Bool ?? true
        h265Visible = defaults.object(forKey: AppConstants.h265VisibleKey) as? Bool ?? true
        av1Visible = defaults.object(forKey: AppConstants.av1VisibleKey) as? Bool ?? true
        tvHEVCVisible = defaults.object(forKey: AppConstants.tvHEVCVisibleKey) as? Bool ?? true
        tvAVCIntraVisible = defaults.object(forKey: AppConstants.tvAVCIntraVisibleKey) as? Bool ?? true
        proresVisible = defaults.object(forKey: AppConstants.proresVisibleKey) as? Bool ?? true
        proxyVisible = defaults.object(forKey: AppConstants.proxyVisibleKey) as? Bool ?? true
        streamCopyVisible = defaults.object(forKey: AppConstants.streamCopyVisibleKey) as? Bool ?? true
        audioWAVVisible = defaults.object(forKey: AppConstants.audioWAVVisibleKey) as? Bool ?? true
        audioAACVisible = defaults.object(forKey: AppConstants.audioAACVisibleKey) as? Bool ?? true
        imageSequenceVisible = defaults.object(forKey: AppConstants.imageSequenceVisibleKey) as? Bool ?? true
        dcpVisible = defaults.object(forKey: AppConstants.dcpVisibleKey) as? Bool ?? true

        // Load custom preset activation (default to false)
        customPreset1Active = defaults.bool(forKey: AppConstants.customPreset1ActiveKey)
        customPreset2Active = defaults.bool(forKey: AppConstants.customPreset2ActiveKey)
        customPreset3Active = defaults.bool(forKey: AppConstants.customPreset3ActiveKey)
        customPreset4Active = defaults.bool(forKey: AppConstants.customPreset4ActiveKey)
        customPreset5Active = defaults.bool(forKey: AppConstants.customPreset5ActiveKey)
        customPreset6Active = defaults.bool(forKey: AppConstants.customPreset6ActiveKey)
        customPreset7Active = defaults.bool(forKey: AppConstants.customPreset7ActiveKey)
        customPreset8Active = defaults.bool(forKey: AppConstants.customPreset8ActiveKey)
        customPreset9Active = defaults.bool(forKey: AppConstants.customPreset9ActiveKey)
        customPreset10Active = defaults.bool(forKey: AppConstants.customPreset10ActiveKey)

        // Observe UserDefaults changes for reactive updates
        setupObservers()
    }

    // MARK: - Public API

    /// Returns the list of presets currently visible in the picker
    var visiblePresets: [ExportPreset] {
        ExportPreset.allCases.filter { preset in
            switch preset {
            case .videoLoop: return videoLoopVisible
            case .videoLoopWithSound: return videoLoopWithSoundVisible
            case .animatedStill: return animatedStillVisible
            case .h264: return h264Visible
            case .h265: return h265Visible
            case .av1: return av1Visible
            case .tvHEVC: return tvHEVCVisible
            case .tvAVCIntra: return tvAVCIntraVisible
            case .prores: return proresVisible
            case .proxy: return proxyVisible
            case .streamCopy: return streamCopyVisible
            case .audioUncompressedWAV: return audioWAVVisible
            case .audioStereoAAC: return audioAACVisible
            case .imageSequence: return imageSequenceVisible
            case .dcp: return dcpVisible
            case .custom1: return customPreset1Active
            case .custom2: return customPreset2Active
            case .custom3: return customPreset3Active
            case .custom4: return customPreset4Active
            case .custom5: return customPreset5Active
            case .custom6: return customPreset6Active
            case .custom7: return customPreset7Active
            case .custom8: return customPreset8Active
            case .custom9: return customPreset9Active
            case .custom10: return customPreset10Active
            }
        }
    }

    /// Returns the display name for a preset, using stored custom names for custom presets
    func displayName(for preset: ExportPreset) -> String {
        guard let slot = preset.customSlotIndex else {
            return preset.displayName
        }
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = fallbackSuffixes.indices.contains(slot) ? fallbackSuffixes[slot] : "Custom Preset"
        let storedSuffix: String
        switch slot {
        case 0: storedSuffix = customPreset1Name
        case 1: storedSuffix = customPreset2Name
        case 2: storedSuffix = customPreset3Name
        case 3: storedSuffix = customPreset4Name
        case 4: storedSuffix = customPreset5Name
        case 5: storedSuffix = customPreset6Name
        case 6: storedSuffix = customPreset7Name
        case 7: storedSuffix = customPreset8Name
        case 8: storedSuffix = customPreset9Name
        case 9: storedSuffix = customPreset10Name
        default: storedSuffix = fallbackSuffix
        }
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, prefix: prefix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }

    /// Loads the default preset from UserDefaults
    func loadDefaultPreset() -> ExportPreset {
        let rawValue = UserDefaults.standard.string(forKey: AppConstants.defaultPresetKey) ?? ExportPreset.videoLoop.rawValue
        return ExportPreset(rawValue: rawValue) ?? .videoLoop
    }

    /// Applies auto-mute settings when switching between presets
    /// - Parameters:
    ///   - items: The video items to modify
    ///   - oldPreset: The previous preset
    ///   - newPreset: The new preset being selected
    ///   - videoLoopDefaultMuted: Whether VideoLoop defaults to muted
    func applyAutoMuteSettings(
        to items: inout [VideoItem],
        oldPreset: ExportPreset,
        newPreset: ExportPreset,
        videoLoopDefaultMuted: Bool
    ) {
        // Auto-mute items when switching to VideoLoop preset if the setting is enabled
        if newPreset == .videoLoop && videoLoopDefaultMuted {
            for index in items.indices where items[index].status == .waiting {
                items[index].isMuted = true
            }
        }
        // Auto-unmute items when switching away from VideoLoop
        else if oldPreset == .videoLoop && newPreset != .videoLoop {
            for index in items.indices where items[index].status == .waiting {
                items[index].isMuted = false
            }
        }
    }

    /// Reloads visibility settings from UserDefaults
    /// Call this after settings are changed in the Settings view
    func reloadVisibilitySettings() {
        let defaults = UserDefaults.standard

        videoLoopVisible = defaults.object(forKey: AppConstants.videoLoopVisibleKey) as? Bool ?? true
        videoLoopWithSoundVisible = defaults.object(forKey: AppConstants.videoLoopWithSoundVisibleKey) as? Bool ?? true
        animatedStillVisible = defaults.object(forKey: AppConstants.animatedStillVisibleKey) as? Bool ?? true
        h264Visible = defaults.object(forKey: AppConstants.h264VisibleKey) as? Bool ?? true
        h265Visible = defaults.object(forKey: AppConstants.h265VisibleKey) as? Bool ?? true
        av1Visible = defaults.object(forKey: AppConstants.av1VisibleKey) as? Bool ?? true
        tvHEVCVisible = defaults.object(forKey: AppConstants.tvHEVCVisibleKey) as? Bool ?? true
        tvAVCIntraVisible = defaults.object(forKey: AppConstants.tvAVCIntraVisibleKey) as? Bool ?? true
        proresVisible = defaults.object(forKey: AppConstants.proresVisibleKey) as? Bool ?? true
        proxyVisible = defaults.object(forKey: AppConstants.proxyVisibleKey) as? Bool ?? true
        streamCopyVisible = defaults.object(forKey: AppConstants.streamCopyVisibleKey) as? Bool ?? true
        audioWAVVisible = defaults.object(forKey: AppConstants.audioWAVVisibleKey) as? Bool ?? true
        audioAACVisible = defaults.object(forKey: AppConstants.audioAACVisibleKey) as? Bool ?? true
        imageSequenceVisible = defaults.object(forKey: AppConstants.imageSequenceVisibleKey) as? Bool ?? true
        dcpVisible = defaults.object(forKey: AppConstants.dcpVisibleKey) as? Bool ?? true

        customPreset1Active = defaults.bool(forKey: AppConstants.customPreset1ActiveKey)
        customPreset2Active = defaults.bool(forKey: AppConstants.customPreset2ActiveKey)
        customPreset3Active = defaults.bool(forKey: AppConstants.customPreset3ActiveKey)
        customPreset4Active = defaults.bool(forKey: AppConstants.customPreset4ActiveKey)
        customPreset5Active = defaults.bool(forKey: AppConstants.customPreset5ActiveKey)
        customPreset6Active = defaults.bool(forKey: AppConstants.customPreset6ActiveKey)
        customPreset7Active = defaults.bool(forKey: AppConstants.customPreset7ActiveKey)
        customPreset8Active = defaults.bool(forKey: AppConstants.customPreset8ActiveKey)
        customPreset9Active = defaults.bool(forKey: AppConstants.customPreset9ActiveKey)
        customPreset10Active = defaults.bool(forKey: AppConstants.customPreset10ActiveKey)
    }

    /// Reloads custom preset names from UserDefaults
    func reloadCustomPresetNames() {
        let defaults = UserDefaults.standard

        customPreset1Name = defaults.string(forKey: AppConstants.customPreset1NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[0]
        customPreset2Name = defaults.string(forKey: AppConstants.customPreset2NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[1]
        customPreset3Name = defaults.string(forKey: AppConstants.customPreset3NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[2]
        customPreset4Name = defaults.string(forKey: AppConstants.customPreset4NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[3]
        customPreset5Name = defaults.string(forKey: AppConstants.customPreset5NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[4]
        customPreset6Name = defaults.string(forKey: AppConstants.customPreset6NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[5]
        customPreset7Name = defaults.string(forKey: AppConstants.customPreset7NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[6]
        customPreset8Name = defaults.string(forKey: AppConstants.customPreset8NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[7]
        customPreset9Name = defaults.string(forKey: AppConstants.customPreset9NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[8]
        customPreset10Name = defaults.string(forKey: AppConstants.customPreset10NameKey) ?? AppConstants.defaultCustomPresetDisplayNames[9]
    }

    // MARK: - Private Helpers

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let remainder = trimmed[cutoff...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let remainder = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        return trimmed
    }

    private func setupObservers() {
        // Observe UserDefaults changes to keep visibility in sync
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadVisibilitySettings()
                self?.reloadCustomPresetNames()
            }
        }
    }
}
