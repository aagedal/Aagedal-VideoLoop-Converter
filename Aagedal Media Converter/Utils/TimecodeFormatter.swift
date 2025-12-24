// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Utility for formatting time as timecode (HH:MM:SS:FF)

import Foundation

/// Represents how timecode should be displayed
enum TimecodeDisplayMode: String, CaseIterable {
    /// Relative timecode starting from 00:00:00:00
    case relative = "relative"
    /// Source timecode from the file's embedded metadata
    case source = "source"
    /// Frame count from 0 to total frames
    case frames = "frames"

    var prefix: String {
        switch self {
        case .relative: return "REL TC"
        case .source: return "SRC TC"
        case .frames: return "FRM"
        }
    }

    var displayName: String {
        switch self {
        case .relative: return "Relative Timecode (REL TC)"
        case .source: return "Source Timecode (SRC TC)"
        case .frames: return "Frame Count (FRM)"
        }
    }

    /// Cycles to the next display mode (relative -> source -> frames -> relative)
    mutating func toggle() {
        switch self {
        case .relative: self = .source
        case .source: self = .frames
        case .frames: self = .relative
        }
    }

    /// Returns the preferred timecode display mode from UserDefaults
    static var preferred: TimecodeDisplayMode {
        let rawValue = UserDefaults.standard.string(forKey: AppConstants.preferredTimecodeDisplayModeKey)
            ?? AppConstants.defaultPreferredTimecodeDisplayMode
        return TimecodeDisplayMode(rawValue: rawValue) ?? .relative
    }
}

struct TimecodeFormatter {
    /// Convert seconds to timecode string (HH:MM:SS:FF or HH:MM:SS;FF)
    /// - Parameters:
    ///   - seconds: Time in seconds to format
    ///   - frameRate: Frame rate of the video (defaults to 30 if not provided)
    ///   - startTimecode: Optional starting timecode to offset from (e.g., "01:00:00:00")
    ///   - useDropFrame: Whether to use drop-frame notation (semicolon separator)
    /// - Returns: Formatted timecode string
    static func timecode(
        from seconds: Double,
        frameRate: Double? = nil,
        startTimecode: String? = nil,
        useDropFrame: Bool = false
    ) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "--:--:--:--"
        }

        let fps = frameRate ?? 30.0
        let roundedFps = Int(fps.rounded())

        // Parse start timecode if provided
        let startOffsetFrames: Int
        if let startTC = startTimecode {
            startOffsetFrames = parseTimecodeToFrames(startTC, fps: fps)
        } else {
            startOffsetFrames = 0
        }

        // Convert seconds to total frames
        let totalFramesFromSeconds = Int((seconds * fps).rounded())
        let totalFrames = startOffsetFrames + totalFramesFromSeconds

        // Break down into timecode components
        let frames = totalFrames % roundedFps
        var remainingFrames = totalFrames / roundedFps

        let secs = remainingFrames % 60
        remainingFrames /= 60

        let mins = remainingFrames % 60
        remainingFrames /= 60

        let hours = remainingFrames % 24

        let separator = useDropFrame ? ";" : ":"

        return String(format: "%02d:%02d:%02d%@%02d", hours, mins, secs, separator, frames)
    }

    /// Parse a timecode string to total frame count
    /// - Parameters:
    ///   - timecode: Timecode string in format HH:MM:SS:FF or HH:MM:SS;FF
    ///   - fps: Frame rate to use for calculation
    /// - Returns: Total number of frames
    static func parseTimecodeToFrames(_ timecode: String, fps: Double) -> Int {
        let components = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return 0
        }

        let roundedFps = Int(fps.rounded())

        var totalFrames = hours * 3600 * roundedFps
        totalFrames += minutes * 60 * roundedFps
        totalFrames += seconds * roundedFps
        totalFrames += frames

        return totalFrames
    }

    /// Determine the effective starting timecode for a video item
    /// - Parameter item: The video item to check
    /// - Returns: Starting timecode string, or nil if none available
    static func effectiveStartTimecode(for item: VideoItem) -> String? {
        // Priority 1: Manual override
        if let config = item.timecodeConfig {
            switch config.mode {
            case .manual(let tc):
                return tc
            case .preserveSource:
                // Priority 2: Source timecode from metadata
                return item.metadata?.timecode
            }
        }

        // Default fallback: use source timecode from metadata if available
        return item.metadata?.timecode
    }

    /// Check if timecode should be used for display
    /// - Parameter item: The video item to check
    /// - Returns: True if timecode should be displayed
    static func shouldUseTimecode(for item: VideoItem) -> Bool {
        // Use timecode if:
        // 1. User has configured it (manual or preserve source)
        // 2. Source has timecode and no explicit disable
        if let config = item.timecodeConfig {
            return config.isActive
        }

        // Default: use timecode if source has it
        return item.metadata?.timecode != nil
    }

    /// Get the frame rate to use for timecode calculations
    /// - Parameter item: The video item
    /// - Returns: Frame rate in fps, defaults to 30 if not available
    static func effectiveFrameRate(for item: VideoItem) -> Double {
        if let frameRate = item.metadata?.primaryVideoStream?.frameRate?.value, frameRate > 0 {
            return frameRate
        }
        // Default to 30fps for audio-only or unknown
        return 30.0
    }

    /// Format time for display in trim player
    /// Always uses timecode format (HH:MM:SS:FF)
    /// - Parameters:
    ///   - seconds: Time in seconds
    ///   - item: Video item to get timecode configuration from
    ///   - isOutPoint: If true, adds one frame to make the display inclusive
    ///   - isDuration: If true, displays as duration (length) without start timecode offset
    /// - Returns: Formatted time string in timecode format
    static func formatTimeForDisplay(seconds: Double, item: VideoItem, isOutPoint: Bool = false, isDuration: Bool = false) -> String {
        // Always use timecode format in trim player
        let startTC = isDuration ? nil : effectiveStartTimecode(for: item)
        let frameRate = effectiveFrameRate(for: item)
        let useDropFrame = startTC?.contains(";") ?? false

        // For out-points, add one frame to make the display inclusive of the frame at that position
        let adjustedSeconds = isOutPoint ? seconds + (1.0 / frameRate) : seconds

        return timecode(
            from: adjustedSeconds,
            frameRate: frameRate,
            startTimecode: startTC,
            useDropFrame: useDropFrame
        )
    }

    /// Format time in traditional HH:MM:SS or MM:SS format
    /// - Parameter seconds: Time in seconds
    /// - Returns: Formatted time string
    static func formatTraditionalTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    /// Format time for display with explicit mode selection
    /// - Parameters:
    ///   - seconds: Time in seconds
    ///   - item: Video item to get timecode configuration from
    ///   - mode: Whether to display relative, source timecode, or frame count
    ///   - isOutPoint: If true, adds one frame to make the display inclusive
    ///   - isDuration: If true, displays as duration (length) without start timecode offset
    ///   - includePrefix: If true, includes the mode prefix (SRC TC / REL TC / FRM)
    /// - Returns: Formatted time string in timecode format or frame count
    static func formatTimeForDisplayWithMode(
        seconds: Double,
        item: VideoItem,
        mode: TimecodeDisplayMode,
        isOutPoint: Bool = false,
        isDuration: Bool = false,
        includePrefix: Bool = false
    ) -> String {
        let frameRate = effectiveFrameRate(for: item)
        
        // For out-points, add one frame to make the display inclusive of the frame at that position
        let adjustedSeconds = isOutPoint ? seconds + (1.0 / frameRate) : seconds
        
        let displayString: String
        
        switch mode {
        case .relative:
            // Always start from 00:00:00:00
            displayString = timecode(
                from: adjustedSeconds,
                frameRate: frameRate,
                startTimecode: nil,
                useDropFrame: false
            )
        case .source:
            // Use source timecode if available and not showing duration
            let startTC = isDuration ? nil : effectiveStartTimecode(for: item)
            let useDropFrame = startTC?.contains(";") ?? false
            displayString = timecode(
                from: adjustedSeconds,
                frameRate: frameRate,
                startTimecode: startTC,
                useDropFrame: useDropFrame
            )
        case .frames:
            // Display as frame count from 0
            let frameNumber = Int((adjustedSeconds * frameRate).rounded())
            displayString = String(frameNumber)
        }
        
        if includePrefix {
            return "\(mode.prefix) \(displayString)"
        }
        return displayString
    }
}
