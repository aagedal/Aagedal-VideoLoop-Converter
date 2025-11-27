// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct TimecodeView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    @State private var selectedMode: TimecodeMode = .preserveSource
    @State private var manualTimecode: String = "00:00:00:00"
    @State private var isValidTimecode: Bool = true

    private enum TimecodeMode: String, CaseIterable, Identifiable {
        case preserveSource = "Preserve Source"
        case manual = "Manual Override"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timecode Configuration")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close timecode configuration")
                .keyboardShortcut(.escape, modifiers: [])
            }

            // Content
            VStack(alignment: .leading, spacing: 16) {
                // Mode picker
                Picker("Timecode Mode", selection: $selectedMode) {
                    ForEach(TimecodeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedMode) { _, newMode in
                    updateTimecodeConfig()
                }

                Divider()

                // Source timecode info
                if selectedMode == .preserveSource {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("The timecode from the source file will be copied to the output.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        if let sourceTimecode = item.metadata?.timecode {
                            HStack {
                                Text("Source Timecode:")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sourceTimecode)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(6)
                            }
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No timecode found in source file.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }

                // Manual timecode input
                if selectedMode == .manual {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("Enter a custom start timecode for the output file.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Timecode")
                                .font(.subheadline.weight(.semibold))

                            TextField("00:00:00:00", text: $manualTimecode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: manualTimecode) { _, newValue in
                                    let sanitized = sanitizeTimecode(newValue)
                                    if sanitized != newValue {
                                        manualTimecode = sanitized
                                    }
                                    isValidTimecode = validateTimecode(sanitized)
                                    updateTimecodeConfig()
                                }

                            if !isValidTimecode {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                    Text(validationErrorMessage())
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            } else {
                                let maxFrames = getMaxFramesFromMetadata()
                                Text("Format: HH:MM:SS:FF (hours: 00-23, frames: 00-\(String(format: "%02d", maxFrames - 1))) or HH:MM:SS;FF for drop-frame")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }

                Spacer()

                // Action buttons
                HStack {
                    Button("Disable Timecode") {
                        item.timecodeConfig = nil
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 300, idealHeight: 400)
        .onAppear {
            initializeFromConfig()
        }
    }

    private func initializeFromConfig() {
        if let config = item.timecodeConfig {
            switch config.mode {
            case .preserveSource:
                selectedMode = .preserveSource
            case .manual(let tc):
                selectedMode = .manual
                manualTimecode = tc
            }
        } else {
            selectedMode = .preserveSource
            manualTimecode = item.metadata?.timecode ?? "00:00:00:00"
        }
    }

    private func updateTimecodeConfig() {
        switch selectedMode {
        case .preserveSource:
            item.timecodeConfig = TimecodeConfig(mode: .preserveSource)
        case .manual:
            item.timecodeConfig = TimecodeConfig(mode: .manual(manualTimecode))
        }
    }

    private func sanitizeTimecode(_ input: String) -> String {
        // Only allow digits, colons, and semicolons
        let allowed = CharacterSet(charactersIn: "0123456789:;")
        let filtered = input.filter { char in
            char.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        // Limit length to 11 characters (HH:MM:SS:FF or HH:MM:SS;FF)
        let truncated = String(filtered.prefix(11))

        return truncated
    }

    private func validateTimecode(_ input: String) -> Bool {
        // Valid formats: HH:MM:SS:FF or HH:MM:SS;FF
        // Regex pattern for timecode
        let pattern = "^\\d{2}:\\d{2}:\\d{2}[:;]\\d{2}$"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.firstMatch(in: input, range: range)

        if matches == nil {
            return false
        }

        // Additional validation: hours, minutes, seconds, frames should be in valid ranges
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return false
        }

        // Hours: 0-23 (24-hour format)
        guard hours < 24 else { return false }

        // Minutes: 0-59
        guard minutes < 60 else { return false }

        // Seconds: 0-59
        guard seconds < 60 else { return false }

        // Frames: 0 to (frameRate - 1)
        // Get frame rate from source metadata
        let maxFrames = getMaxFramesFromMetadata()
        guard frames < maxFrames else { return false }

        return true
    }

    private func getMaxFramesFromMetadata() -> Int {
        // Get frame rate from source video metadata
        guard let frameRate = item.metadata?.videoStream?.frameRate?.value else {
            // Default to 30 fps if unknown (common for video)
            return 30
        }

        // Round frame rate to nearest integer
        // Most common rates: 23.976 → 24, 29.97 → 30, 59.94 → 60, etc.
        let roundedFrameRate = Int(frameRate.rounded())

        return roundedFrameRate
    }

    private func validationErrorMessage() -> String {
        // Provide specific error message based on what's wrong
        let components = manualTimecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        if components.count != 4 {
            return "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF"
        }

        guard let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF"
        }

        if hours >= 24 {
            return "Hours must be 00-23"
        }

        if minutes >= 60 {
            return "Minutes must be 00-59"
        }

        if seconds >= 60 {
            return "Seconds must be 00-59"
        }

        let maxFrames = getMaxFramesFromMetadata()
        if frames >= maxFrames {
            return "Frames must be 00-\(String(format: "%02d", maxFrames - 1)) (based on \(maxFrames)fps source)"
        }

        return "Invalid timecode format"
    }
}
