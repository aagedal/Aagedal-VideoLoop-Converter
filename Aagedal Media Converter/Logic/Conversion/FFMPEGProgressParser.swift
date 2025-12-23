//
//  FFMPEGProgressParser.swift
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

import Foundation

/// Tracks frame stall state for detecting when FFmpeg is closing the file
final class FrameStallTracker: @unchecked Sendable {
    private var lastFrame: Int = -1
    private var lastFrameChangeTime: Date = Date()
    private var hasReportedStall: Bool = false
    private let stallThreshold: TimeInterval = 5.0  // 5 seconds

    /// Updates the tracker with a new frame number
    /// - Returns: "Closing file..." if stalled, nil otherwise
    func update(frame: Int) -> String? {
        let now = Date()

        if frame != lastFrame {
            // Frame changed, reset stall tracking
            lastFrame = frame
            lastFrameChangeTime = now
            hasReportedStall = false
            return nil
        }

        // Frame hasn't changed - check for stall
        let stallDuration = now.timeIntervalSince(lastFrameChangeTime)
        if stallDuration >= stallThreshold && !hasReportedStall {
            hasReportedStall = true
            return "Closing file..."
        }

        return hasReportedStall ? "Closing file..." : nil
    }

    func reset() {
        lastFrame = -1
        lastFrameChangeTime = Date()
        hasReportedStall = false
    }
}

enum FFMPEGProgressParser {
    /// Processes FFmpeg output to extract progress and duration information.
    /// - Parameters:
    ///   - output: The FFmpeg output string to process
    ///   - totalDuration: The current total duration if already known
    ///   - effectiveDuration: The effective duration for ETA calculation (trimmed duration if applicable)
    ///   - frameRate: Video frame rate for frame-based progress calculation (default 24fps)
    ///   - frameStallTracker: Optional tracker for detecting frame stalls
    ///   - progressUpdate: Callback to report progress updates
    /// - Returns: A tuple containing the updated total duration (if found) and the current progress
    static func handleOutput(
        _ output: String,
        totalDuration: Double?,
        effectiveDuration: Double?,
        frameRate: Double = 24.0,
        frameStallTracker: FrameStallTracker? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) -> (Double?, (Double, String?)?) {
        var newTotalDuration = totalDuration

        // Try to parse the total duration if not already known
        if newTotalDuration == nil, let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            print("Total Duration: \(duration) seconds")
        }

        let durationForProgress = effectiveDuration ?? newTotalDuration

        var progressTuple: (Double, String?)? = nil

        // Try time-based progress first (works for encoding)
        if let progress = ParsingUtils.parseTimeProgress(from: output, totalDuration: durationForProgress) {
            Task { @MainActor in
                progressUpdate(progress.0, progress.1)
            }
            progressTuple = progress
        }
        // Fall back to frame-based progress (works for stream copy)
        else if let frameProgress = ParsingUtils.parseFrameProgress(from: output, totalDuration: durationForProgress, frameRate: frameRate) {
            var etaString = frameProgress.1

            // Check for frame stall (FFmpeg closing file)
            if let tracker = frameStallTracker, let frame = frameProgress.2 {
                if let stallMessage = tracker.update(frame: frame) {
                    etaString = stallMessage
                }
            }

            Task { @MainActor in
                progressUpdate(frameProgress.0, etaString)
            }
            progressTuple = (frameProgress.0, etaString)
        }

        return (newTotalDuration, progressTuple)
    }
}
