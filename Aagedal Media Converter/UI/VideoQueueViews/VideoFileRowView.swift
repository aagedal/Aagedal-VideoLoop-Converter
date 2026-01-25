// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVFoundation
import AppKit
import ImageIO

struct VideoFileRowView: View {
    @Binding var file: VideoItem
    @Binding var focusedCommentID: UUID?
    let preset: ExportPreset
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: (_ optionKeyPressed: Bool) -> Void
    var onCancelDownload: (() -> Void)?
    var onStopLiveRecording: (() -> Void)?
    var onRetryDownload: (() -> Void)?
    var onForceRedownload: (() -> Void)?
    var onCancelScheduledDownload: (() -> Void)?
    var onTranscribeOnly: (() -> Void)?
    var onRenameOutputFileName: ((String?) -> Void)? = nil
    /// Indicates if this row is selected in the list
    var isSelected: Bool = false
    var onCommentFocusChange: (UUID, Bool) -> Void = { _, _ in }
    var onPlayFullscreen: () -> Void = {}
    var mergeClipsEnabled: Bool = false
    var mergeClipsAvailable: Bool = false
    var showCommentField: Bool = true
    var showDateTagButton: Bool = true
    var isCompactMode: Bool = false

    // Show yellow warning icon when VideoLoop preset is used on clips longer than 15 s
    private var showDurationWarning: Bool {
        preset == .videoLoop && file.durationSeconds > 15
    }

    private var shouldShowMergeIndicator: Bool {
        mergeClipsAvailable
    }

    private var mergeIndicatorColor: Color {
        mergeClipsEnabled ? .green : Color.gray.opacity(0.55)
    }

    private var mergeIndicatorHelpText: String {
        mergeClipsEnabled
            ? "Merge enabled: this clip will be concatenated into a single output file."
            : "Clips are merge-compatible. Enable merge to export a single concatenated file."
    }

    // Upload button computed properties
    private var uploadIconName: String {
        if file.uploadSourceFile {
            return "arrow.up.doc.fill"  // Different icon for source file upload
        } else if file.uploadEnabled {
            return "icloud.and.arrow.up.fill"
        } else {
            return "icloud.and.arrow.up"
        }
    }

    private var uploadIconColor: Color {
        if file.uploadSourceFile {
            return .orange  // Orange for source file upload
        } else if file.uploadEnabled {
            return .blue
        } else {
            return .secondary
        }
    }

    private var uploadHelpText: String {
        guard UploadManager.shared.isConfigured else {
            return "Configure upload in Settings > Upload"
        }
        if file.uploadSourceFile {
            return "Source file will upload immediately. Option+click to disable."
        } else if file.uploadEnabled {
            return "Encoded file will upload after encoding. Option+click to upload source file instead."
        } else {
            return "Enable upload after encoding. Option+click to upload source file immediately."
        }
    }

    // Subtitle button computed properties
    private var subtitleIconName: String {
        file.subtitleEnabled ? "captions.bubble.fill" : "captions.bubble"
    }

    private var subtitleIconColor: Color {
        file.subtitleEnabled ? .green : .secondary
    }

    private var subtitleHelpText: String {
        if file.subtitleEnabled {
            return "Subtitle generation enabled. SRT will be created after encoding. Option+click to generate SRT only (no encoding)."
        } else {
            return "Enable subtitle generation after encoding. Option+click to generate SRT only (no encoding)."
        }
    }

    private func isOptionKeyPressed() -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        return flags.contains(.option)
    }

    @FocusState private var isCommentFieldFocused: Bool
    @State private var isThumbnailHovered = false
    @State private var showPreview = false
    @State private var showMetadata = false
    @State private var showAudioRouting = false
    @State private var showTimecode = false
    @State private var cachedThumbnail: NSImage?
    @State private var localComment: String = ""
    @State private var isBeingDeleted = false
    @State private var showCommentPreviewPopover = false
    @State private var isEditingOutputName = false
    @State private var outputNameDraft: String = ""
    @FocusState private var isOutputNameFieldFocused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 0.8)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            
            VStack(spacing: 0) {
                HStack {
                    thumbnailView
                    
                    VStack(alignment: .leading, spacing: 4) {
                        // Input and output file names
                        HStack {
                            Text(file.name)
                                .font(.headline)
                            // Duration warning icon
                            Text("→")
                            HStack(spacing: 4) {
                                if isEditingOutputName {
                                    TextField("Output filename", text: $outputNameDraft)
                                        .font(.headline)
                                        .textFieldStyle(.plain)
                                        .focused($isOutputNameFieldFocused)
                                        .onSubmit {
                                            commitOutputNameEdit()
                                        }
                                        .onExitCommand {
                                            cancelOutputNameEdit()
                                        }
                                        .onChange(of: isOutputNameFieldFocused) { _, isFocused in
                                            if !isFocused && isEditingOutputName {
                                                commitOutputNameEdit()
                                            }
                                        }
                                        .onAppear {
                                            outputNameDraft = displayOutputFilename()
                                            isOutputNameFieldFocused = true
                                        }
                                } else {
                                    Text(displayOutputFilename())
                                        .font(.headline)
                                        .foregroundColor((file.status == .waiting && file.outputFileExists) ? .orange : .primary)
                                        .onTapGesture(count: 2) {
                                            beginOutputNameEdit()
                                        }
                                }
                                if shouldShowMergeIndicator {
                                    Image(systemName: "link")
                                        .rotationEffect(.degrees(90))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(mergeIndicatorColor)
                                        .help(mergeIndicatorHelpText)
                                        .accessibilityLabel(mergeClipsEnabled ? "Merge enabled" : "Merge available")
                                }
                                
                                if let outputURL = file.outputURL {
                                    HStack(spacing: 6) {
                                        if file.status == .waiting && file.outputFileExists {
                                            Button(action: {
                                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                            }) {
                                                Image(systemName: "magnifyingglass.circle.fill")
                                                    .foregroundColor(.orange)
                                                    .help("Output file already exists and will be overwritten during conversion. Click to show in Finder.")
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                            dragIcon(
                                                for: outputURL,
                                                color: Color.orange,
                                                helpText: "Output file already exists and will be overwritten during conversion. Drag to share or archive before converting."
                                            )
                                        }

                                if file.status == .done {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    }) {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .foregroundColor(.blue)
                                            .help("Show in Finder")
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    dragIcon(
                                        for: outputURL,
                                        color: Color.blue,
                                        helpText: "Drag this icon to share the exported file with other apps."
                                    )
                                }
                                if file.sourceURL != nil && !file.isDownloading {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    }) {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .foregroundColor(downloadActionColor)
                                            .help("Show downloaded file")
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                            }
                        }
                            }
                            if file.isLiveStreamRecording {
                                liveRecordingBadge
                            }
                            Spacer()
                        }
                        
                        // Compact mode: action buttons row
                        if isCompactMode {
                            HStack {
                                HStack{
                                    compactActionButtonsRow
                                }
                                
    
                                Spacer()
                                // Action buttons (delete/reset) - right aligned
                                HStack {
                                    Spacer()
                                if file.isDownloading {
                                    // Stop button - keeps the partial file and imports it
                                    Button(action: {
                                        onStopLiveRecording?()
                                    }) {
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 14))
                                            .frame(width: 20, height: 20)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(.orange)
                                    .help("Stop download and keep partial file")
                                    // Cancel button - discards the download
                                    Button(action: {
                                        onCancelDownload?()
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .frame(width: 20, height: 20)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(.red)
                                    .help("Cancel and discard download")
                                } else if file.scheduledDownloadTime != nil {
                                        Button(action: { onCancelScheduledDownload?() }) {
                                            Image(systemName: "clock.badge.xmark")
                                                .foregroundColor(.cyan)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Cancel scheduled download")
                                    } else if file.fileAlreadyExistsPath != nil {
                                        Button(action: { onForceRedownload?() }) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .foregroundColor(.orange)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Redownload (overwrite existing file)")
                                    } else if file.downloadError != nil {
                                        Button(action: { onRetryDownload?() }) {
                                            Image(systemName: "arrow.clockwise.circle")
                                                .foregroundColor(.orange)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Retry download")
                                    } else if file.status == .converting {
                                        Button(action: onCancel) {
                                            Image(systemName: "xmark.circle")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Cancel conversion")
                                    } else {
                                        Button(action: {
                                            isBeingDeleted = true
                                            if isCommentFieldFocused || focusedCommentID == file.id {
                                                isCommentFieldFocused = false
                                                focusedCommentID = nil
                                            }
                                            onDelete()
                                        }) {
                                            Image(systemName: "clear")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Remove from list")

                                        FileResetButton(
                                            isEnabled: file.status != .converting && file.status != .waiting,
                                            onReset: onReset
                                        )
                                    }
                                }
                                .frame(minWidth: 44, alignment: .trailing)
                            }
                        }

                        // Progress bar (shown when converting, downloading, uploading, or transcribing)
                        if file.status == .converting || file.isDownloading || file.uploadStatus == .uploading || file.subtitleStatus.isInProgress {
                            if (file.isDownloading && isDownloadPreparing) || isSubtitlePreparing || file.isLiveStreamRecording {
                                // Indeterminate progress for preparing or live stream recording
                                ProgressView()
                                    .progressViewStyle(LinearProgressViewStyle())
                                    .tint(progressBarColor)
                            } else {
                                ProgressView(value: progressBarValue)
                                    .progressViewStyle(LinearProgressViewStyle())
                                    .tint(progressBarColor)
                            }
                        }

                        // Standard mode: duration and size line
                        if !isCompactMode {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(TimecodeFormatter.formatTimeForDisplay(seconds: file.durationSeconds, item: file, isDuration: true))
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .help("Input duration")
                                if showDurationWarning {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                                        .foregroundColor(.yellow)
                                        .help("Duration exceeds 15 seconds. VideoLoops are best suited for shorter videos.")
                                }

                                Text("•")
                                    .foregroundColor(.gray)

                                Text(file.formattedSize)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .help("Input file size")

                                Spacer()

                                // Auto-encode toggle (for download items)
                                if file.isDownloading || file.scheduledDownloadTime != nil {
                                    Button {
                                        file.autoEncodeAfterDownload.toggle()
                                    } label: {
                                        Image(systemName: file.autoEncodeAfterDownload ? "play.fill" : "play")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundColor(file.autoEncodeAfterDownload ? .green : .secondary)
                                    .help(file.autoEncodeAfterDownload ? "Auto-encode enabled" : "Enable auto-encode after download")
                                }

                                // Upload toggle button (Option+click for source file upload)
                                Button {
                                    if isOptionKeyPressed() {
                                        // Option+click: toggle source file upload
                                        file.uploadSourceFile.toggle()
                                        if file.uploadSourceFile {
                                            file.uploadEnabled = true
                                            // Start upload immediately for source files
                                            Task {
                                                await UploadManager.shared.startUpload(itemID: file.id)
                                            }
                                        }
                                    } else {
                                        file.uploadEnabled.toggle()
                                        if !file.uploadEnabled {
                                            file.uploadSourceFile = false
                                        }
                                    }
                                } label: {
                                    Image(systemName: uploadIconName)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(uploadIconColor)
                                .disabled(!UploadManager.shared.isConfigured)
                                .help(uploadHelpText)

                                // Subtitle toggle button (Option+click for transcribe-only)
                                Button {
                                    if isOptionKeyPressed() {
                                        // Option+click: generate SRT only (no encoding)
                                        onTranscribeOnly?()
                                    } else {
                                        file.subtitleEnabled.toggle()
                                    }
                                } label: {
                                    Image(systemName: subtitleIconName)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(subtitleIconColor)
                                .help(subtitleHelpText)

                                // Action buttons container with fixed width
                                HStack(spacing: 4) {
                                    if file.isDownloading {
                                        // Stop button - keeps the partial file and imports it
                                        Button(action: {
                                            onStopLiveRecording?()
                                        }) {
                                            Image(systemName: "stop.circle.fill")
                                                .font(.system(size: 14))
                                                .frame(width: 20, height: 20)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundColor(.orange)
                                        .help("Stop download and keep partial file")
                                        // Cancel button - discards the download
                                        Button(action: {
                                            onCancelDownload?()
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 14))
                                                .frame(width: 20, height: 20)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundColor(.red)
                                        .help("Cancel and discard download")
                                    } else if file.scheduledDownloadTime != nil {
                                        Button(action: { onCancelScheduledDownload?() }) {
                                            Image(systemName: "clock.badge.xmark")
                                                .foregroundColor(.cyan)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Cancel scheduled download")
                                    } else if file.fileAlreadyExistsPath != nil {
                                        Button(action: { onForceRedownload?() }) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .foregroundColor(.orange)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Redownload (overwrite existing file)")
                                    } else if file.downloadError != nil {
                                        Button(action: { onRetryDownload?() }) {
                                            Image(systemName: "arrow.clockwise.circle")
                                                .foregroundColor(.orange)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Retry download")
                                    } else if file.status == .converting {
                                        Button(action: onCancel) {
                                            Image(systemName: "xmark.circle")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Cancel conversion")
                                    } else {
                                        Button(action: {
                                            // Set deletion flag and clear focus BEFORE deleting
                                            isBeingDeleted = true
                                            if isCommentFieldFocused || focusedCommentID == file.id {
                                                isCommentFieldFocused = false
                                                focusedCommentID = nil
                                            }
                                            onDelete()
                                        }) {
                                            Image(systemName: "clear")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                        .help("Remove from list")

                                        FileResetButton(
                                            isEnabled: file.status != .converting && file.status != .waiting && !file.isDownloading,
                                            onReset: onReset
                                        )
                                    }
                                }
                                .frame(minWidth: 44, alignment: .trailing)
                            }
                        }

                        // Status line (simplified in compact mode)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !isCompactMode {
                                if file.status == .waiting && file.outputFileExists {
                                    Text("Existing file will be overwritten")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                }

                                if file.status == .done {
                                    Text("Export: \(file.formattedOutputSize ?? "—")")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                        .help("Exported file size")
                                }
                            }

                            Spacer()

                            // Status text aligned to the right
                            Text(progressText)
                                .font(isCompactMode ? .caption : .subheadline)
                                .foregroundColor(statusColor)
                        }

                        // Comment section (only in standard mode)
                        if !isCompactMode {
                            commentSection
                        }
                    }
                    .padding()
                }
            }
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $showPreview) {
            // Don't show preview for scheduled downloads or items being downloaded
            if showPreview && !file.isDownloading && file.scheduledDownloadTime == nil {
                PreviewPlayerView(item: $file)
            }
        }
        .sheet(isPresented: $showMetadata) {
            if showMetadata {
                VideoMetadataView(item: $file)
            }
        }
        .sheet(isPresented: $showAudioRouting) {
            if showAudioRouting {
                AudioRoutingView(item: $file, preset: preset)
            }
        }
        .sheet(isPresented: $showTimecode) {
            if showTimecode {
                TimecodeView(item: $file)
            }
        }
        .task(id: file.thumbnailData) {
            await Task.yield()
            // Decode thumbnail asynchronously off main thread
            guard let data = file.thumbnailData else {
                await MainActor.run { cachedThumbnail = nil }
                return
            }

            // Use CGImageSource to avoid Apple bug rdar://143602439
            // (kCGImageBlockFormatBGRx8 called for 24-bpp image)
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceShouldAllowFloat: false
                      ] as CFDictionary) else {
                    return NSImage(data: data) // Fallback
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run { cachedThumbnail = image }
        }
        .onAppear {
            // Initialize local comment from file
            localComment = file.comment
        }
        .onChange(of: file.comment) { _, newComment in
            // Sync local comment when file comment changes externally
            // Guard against cycle: only sync if values differ
            if !isCommentFieldFocused && localComment != newComment {
                localComment = newComment
            }
        }
        .onChange(of: localComment) { _, newValue in
            // Sync local comment back to file when changed (only if not being deleted)
            // Guard against cycle: only sync if values differ
            if !isBeingDeleted && isCommentFieldFocused && file.status == .waiting && file.comment != newValue {
                file.comment = newValue
            }
        }
    }

    private var thumbnailView: some View {
        thumbnailImageView
            .overlay(alignment: .topLeading, content: { audioRoutingBadge })
            .overlay(alignment: .topTrailing, content: { timecodeBadge })
            .overlay(alignment: .bottomLeading, content: { trimBadge })
            .overlay(alignment: .bottomTrailing, content: { cropBadge })
            .overlay(alignment: .trailing, content: { uploadBadge })
            .overlay { if isThumbnailHovered { thumbnailHoverOverlay } }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isThumbnailHovered = hovering
                }
            }
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onPlayFullscreen()
                    }
            )
            .onTapGesture { showPreview = true }
    }

    private var thumbnailWidth: CGFloat { isCompactMode ? 133 : 200 }
    private var thumbnailHeight: CGFloat { isCompactMode ? 75 : 150 }

    @ViewBuilder
    private var thumbnailImageView: some View {
        ZStack {
            CheckerboardBackground()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: isCompactMode ? 6 : 9, style: .continuous))
            RoundedRectangle(cornerRadius: isCompactMode ? 6 : 9, style: .continuous)
                .stroke(Color.black.opacity(0.2), lineWidth: 1)
                .frame(width: thumbnailWidth, height: thumbnailHeight)

            if let cachedImage = cachedThumbnail {
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .cornerRadius(isCompactMode ? 3 : 4)
            } else {
                VStack {
                    Image(systemName: "film")
                        .font(isCompactMode ? .title2 : .largeTitle)
                    if !isCompactMode {
                        Text("Generating thumbnail...")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    /// Check if file has surround audio (any track with more than 2 channels)
    private var hasSurroundAudio: Bool {
        guard let audioStreams = file.metadata?.audioStreams else { return false }
        return audioStreams.contains { ($0.channels ?? 0) > 2 }
    }

    @ViewBuilder
    private var audioRoutingBadge: some View {
        if file.isMuted {
            // Show red muted badge when item is muted (icon only)
            badgeView(icon: "speaker.slash.fill", text: "", color: .red)
        } else if let config = file.audioRoutingConfig, config.isCustomized {
            // Show track count badge with downmix indicator if any tracks are being downmixed
            let hasDownmix = config.outputTracks.contains { $0.downmixToStereo }
            if hasDownmix {
                badgeView(icon: "hifispeaker.2", text: "→2ch", color: .green)
            } else if config.hasOutputSurroundWithoutDownmix {
                badgeView(icon: "speaker.wave.3.fill", text: "\(config.outputTracks.count)", color: .orange)
            } else {
                badgeView(icon: "hifispeaker.2", text: "\(config.outputTracks.count)")
            }
        } else if hasSurroundAudio {
            // Show surround warning badge when no custom routing but file has surround audio
            badgeView(icon: "speaker.wave.3.fill", text: "", color: .orange)
        }
    }

    @ViewBuilder
    private var trimBadge: some View {
        if file.trimStart != nil || file.trimEnd != nil {
            badgeView(icon: "scissors", text: TimecodeFormatter.formatTimeForDisplay(seconds: file.trimmedDuration, item: file, isDuration: true))
        }
    }

    @ViewBuilder
    private var timecodeBadge: some View {
        if let timecodeConfig = file.timecodeConfig {
            switch timecodeConfig.mode {
            case .manual:
                badgeView(icon: "timer", text: "MAN")
            case .preserveSource:
                // Show different badge if source has timecode vs doesn't
                if file.metadata?.timecode != nil {
                    badgeView(icon: "timer", text: "SRC")
                } else {
                    badgeView(icon: "timer", text: "No TC")
                }
            }
        } else {
            // No config = disabled
            badgeView(icon: "timer", text: "No TC")
        }
    }

    @ViewBuilder
    private var cropBadge: some View {
        if let cropConfig = file.cropConfig, cropConfig.isActive {
            badgeView(icon: "crop", text: "\(Int(cropConfig.normalizedRect.width * 100))%")
        }
    }

    @ViewBuilder
    private var uploadBadge: some View {
        switch file.uploadStatus {
        case .uploading:
            badgeView(icon: "arrow.up.circle", text: "\(Int(file.uploadProgress * 100))%", color: .orange)
        case .uploaded:
            badgeView(icon: "checkmark.icloud.fill", text: "", color: .green)
        case .failed:
            badgeView(icon: "exclamationmark.icloud.fill", text: "", color: .red)
        case .pending:
            badgeView(icon: "clock.arrow.circlepath", text: "", color: .orange)
        case .cancelled:
            badgeView(icon: "xmark.icloud", text: "", color: .gray)
        case .notQueued:
            if file.uploadEnabled {
                badgeView(icon: "icloud.and.arrow.up", text: "", color: .blue.opacity(0.7))
            }
        }
    }

    private func badgeView(icon: String, text: String, color: Color? = nil) -> some View {
        HStack(spacing: text.isEmpty ? 0 : (isCompactMode ? 2 : 4)) {
            Image(systemName: icon)
                .font(isCompactMode ? .system(size: 8) : .caption2)
            if !text.isEmpty {
                Text(text)
                    .font(isCompactMode ? .system(size: 8) : .caption2)
                    .fontWeight(.medium)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, isCompactMode ? 4 : 8)
        .padding(.vertical, isCompactMode ? 2 : 4)
        .background(
            RoundedRectangle(cornerRadius: isCompactMode ? 4 : 6, style: .continuous)
                .fill(color ?? Color.accentColor)
        )
        .shadow(color: .black.opacity(0.3), radius: isCompactMode ? 1 : 2, x: 0, y: 1)
        .padding(isCompactMode ? 4 : 8)
    }

    private var thumbnailHoverOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isCompactMode ? 6 : 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .allowsHitTesting(false)

            VStack {
                // Top row: Audio Routing (left) and Timecode (right)
                HStack {
                    // Audio Routing button (top-left corner)
                    if let audioStreams = file.metadata?.audioStreams, !audioStreams.isEmpty {
                        Button {
                            showAudioRouting = true
                        } label: {
                            Label("Audio Routing", systemImage: "hifispeaker.2.badge.minus")
                                .labelStyle(.iconOnly)
                                .font(.system(size: isCompactMode ? 14 : 24, weight: .medium))
                                .symbolRenderingMode(file.audioRoutingConfig?.isCustomized == true ? .multicolor : .monochrome)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                        .help(file.audioRoutingConfig?.isCustomized == true ? "Audio routing customized (\(file.audioRoutingConfig?.outputTrackIndices.count ?? 0) tracks)" : "Configure audio track routing")
                    }

                    Spacer()

                    // Timecode button (top-right corner)
                    Button {
                        showTimecode = true
                    } label: {
                        Label("Timecode", systemImage: "timer")
                            .labelStyle(.iconOnly)
                            .font(.system(size: isCompactMode ? 14 : 24, weight: .medium))
                            .symbolRenderingMode(file.timecodeConfig?.isActive == true ? .multicolor : .monochrome)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .help(file.timecodeConfig?.isActive == true ? "Timecode configured" : "Configure output timecode")
                }
                .padding(isCompactMode ? 5 : 10)

                Spacer()

                // Center: Fullscreen play button (only for video files)
                if file.hasVideoStream {
                    Button {
                        onPlayFullscreen()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: isCompactMode ? 24 : 44, weight: .medium))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.4), radius: isCompactMode ? 2 : 4, x: 0, y: isCompactMode ? 1 : 2)
                    }
                    .buttonStyle(.plain)
                    .help("Play fullscreen")
                }

                Spacer()

                // Bottom row: Preview (left), Info (right)
                HStack(spacing: isCompactMode ? 8 : 16) {
                    // Preview button (bottom-left)
                    Button {
                        showPreview = true
                    } label: {
                        Label("Preview", systemImage: "timeline.selection")
                            .labelStyle(.iconOnly)
                            .font(.system(size: isCompactMode ? 16 : 28, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .help("Open preview and trim editor")

                    Spacer()

                    // Metadata button (bottom-right)
                    Button {
                        showMetadata = true
                    } label: {
                        Label("Metadata", systemImage: "info.circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: isCompactMode ? 14 : 24, weight: .medium))
                            .disabled(file.metadata == nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .help("View technical metadata")
                }
                .padding(isCompactMode ? 5 : 10)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Compact Mode Action Buttons

    @ViewBuilder
    private var compactActionButtonsRow: some View {
        HStack(spacing: 8) {
            // Audio Routing button
            if let audioStreams = file.metadata?.audioStreams, !audioStreams.isEmpty {
                Button { showAudioRouting = true } label: {
                    Image(systemName: "hifispeaker.2")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundColor(file.audioRoutingConfig?.isCustomized == true ? .accentColor : .secondary)
                .help("Audio routing")
            }

            // Timecode button
            Button { showTimecode = true } label: {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(file.timecodeConfig?.isActive == true ? .accentColor : .secondary)
            .help("Timecode")

            // Preview/Trim button
            Button { showPreview = true } label: {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("Preview & trim")

            // Fullscreen button (video only)
            if file.hasVideoStream {
                Button {
                    onPlayFullscreen()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("Play fullscreen")
            }

            // Metadata button
            Button { showMetadata = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("View metadata")

            // Auto-encode toggle (for download items)
            if file.isDownloading || file.scheduledDownloadTime != nil {
                Button {
                    file.autoEncodeAfterDownload.toggle()
                } label: {
                    Image(systemName: file.autoEncodeAfterDownload ? "play.fill" : "play")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundColor(file.autoEncodeAfterDownload ? .green : .secondary)
                .help(file.autoEncodeAfterDownload ? "Auto-encode enabled" : "Enable auto-encode after download")
            }

            // Upload toggle button (Option+click for source file upload)
            Button {
                if isOptionKeyPressed() {
                    // Option+click: toggle source file upload
                    file.uploadSourceFile.toggle()
                    if file.uploadSourceFile {
                        file.uploadEnabled = true
                        // Start upload immediately for source files
                        Task {
                            await UploadManager.shared.startUpload(itemID: file.id)
                        }
                    }
                } else {
                    file.uploadEnabled.toggle()
                    if !file.uploadEnabled {
                        file.uploadSourceFile = false
                    }
                }
            } label: {
                Image(systemName: uploadIconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(uploadIconColor)
            .disabled(!UploadManager.shared.isConfigured)
            .help(uploadHelpText)

            // Subtitle toggle button (compact, Option+click for transcribe-only)
            Button {
                if isOptionKeyPressed() {
                    // Option+click: generate SRT only (no encoding)
                    onTranscribeOnly?()
                } else {
                    file.subtitleEnabled.toggle()
                }
            } label: {
                Image(systemName: subtitleIconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(subtitleIconColor)
            .help(subtitleHelpText)
        }
    }

    @ViewBuilder
    private var commentSection: some View {
        let showWaveform = !file.hasVideoStream
        if showCommentField || showDateTagButton || showWaveform {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    if showCommentField {
                        commentInfoButton
                        commentEditor
                    }
                    if showWaveform {
                        waveformControl
                    }
                    if showDateTagButton {
                        dateTagControl
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.top, 12)
        }
    }
    
    private var commentInfoButton: some View {
        Button {
            showCommentPreviewPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showCommentPreviewPopover, arrowEdge: .bottom) {
            CommentPreviewPopoverView(
                comment: file.comment,
                includeDateTag: file.includeDateTag
            )
        }
        .help("Preview full metadata comment")
    }

    private var commentEditor: some View {
        let commentIsEditable = file.status == .waiting
        let commentBinding = Binding(
            get: { 
                // Return local copy - safe even if file is deleted
                return localComment
            },
            set: { (newValue: String) in
                // Update local copy immediately - don't access file here
                localComment = newValue
                // Sync will happen via onChange(of: localComment) below
            }
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .frame(minWidth: 280, maxWidth: .infinity)
            TextField("", text: commentBinding, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1)
                .focused($isCommentFieldFocused)
                .disabled(!commentIsEditable)
                .opacity(commentIsEditable ? 1 : 0.6)
                .frame(height: 28)
                .padding(.horizontal, 8)
                .padding(.top, 1)
                .onSubmit {
                    isCommentFieldFocused = false
                    focusedCommentID = nil
                }
                .onChange(of: file.status) { (_: ConversionManager.ConversionStatus, newStatus: ConversionManager.ConversionStatus) in
                    // Clear focus if file is being deleted or processed
                    if newStatus != .waiting && isCommentFieldFocused {
                        isCommentFieldFocused = false
                        if focusedCommentID == file.id {
                            focusedCommentID = nil
                        }
                    }
                }
            .onChange(of: focusedCommentID) { oldValue, newValue in
                #if DEBUG
                print("📍 focusedCommentID changed: \(oldValue?.uuidString.prefix(8) ?? "nil") → \(newValue?.uuidString.prefix(8) ?? "nil"), myID: \(file.id.uuidString.prefix(8))")
                #endif
                guard commentIsEditable else {
                    if isCommentFieldFocused {
                        isCommentFieldFocused = false
                    }
                    return
                }
                let shouldBeFocused = (newValue == file.id)
                // Guard against redundant updates to prevent feedback loop
                if isCommentFieldFocused != shouldBeFocused {
                    isCommentFieldFocused = shouldBeFocused
                }
            }
            .onChange(of: isCommentFieldFocused) { _, isFocused in
                #if DEBUG
                print("✏️ isCommentFieldFocused changed to \(isFocused) for file \(file.id.uuidString.prefix(8))")
                #endif
                guard commentIsEditable else {
                    if isFocused {
                        isCommentFieldFocused = false
                    }
                    if focusedCommentID == file.id {
                        focusedCommentID = nil
                    }
                    return
                }
                if isFocused {
                    // Guard against redundant updates to prevent feedback loop
                    if focusedCommentID != file.id {
                        focusedCommentID = file.id
                    }
                    onCommentFocusChange(file.id, true)
                } else if focusedCommentID == file.id {
                    focusedCommentID = nil
                    onCommentFocusChange(file.id, false)
                }
            }
            if file.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add a comment (single line)...")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
        }
        .frame(height: 30)
        .onChange(of: isSelected) { _, selected in
            #if DEBUG
            print("📌 Row selection changed to \(selected) for file \(file.id.uuidString.prefix(8))")
            #endif
            guard commentIsEditable else {
                if isCommentFieldFocused {
                    isCommentFieldFocused = false
                }
                if focusedCommentID == file.id {
                    focusedCommentID = nil
                }
                return
            }
            // Clear focus when row is deselected, but do NOT auto-focus on selection
            // to preserve multi-selection behavior
            if !selected && isCommentFieldFocused {
                isCommentFieldFocused = false
                if focusedCommentID == file.id {
                    focusedCommentID = nil
                }
            }
        }
   }

    private var waveformControl: some View {
        let isActive = file.waveformVideoEnabled
        return Button {
            file.waveformVideoEnabled.toggle()
        } label: {
            iconToggleLabel(
                systemName: isActive ? "waveform.circle.fill" : "waveform.circle",
                isActive: isActive,
                disabled: false,
                size: 28,
                cornerRadius: 6
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Waveform video")
        .accessibilityHint("Toggles waveform video generation.")
        .help(waveformHelperText)
    }

    private var dateTagControl: some View {
        let isActive = file.includeDateTag
        return Button {
            file.includeDateTag.toggle()
        } label: {
            iconToggleLabel(
                systemName: isActive ? "calendar.badge.checkmark" : "calendar.badge.minus",
                isActive: isActive,
                disabled: false,
                size: 28,
                cornerRadius: 6,
                tintForegroundWhenActive: true
            )
        }
        .buttonStyle(.plain)
        .frame(width: 56)
        .accessibilityLabel("Include date tag")
        .accessibilityHint("Toggles adding the generation date to metadata.")
        .help(dateTagHelperText)
    }

    private var waveformHelperText: String {
        if file.waveformVideoEnabled {
            return "Waveform video will be generated for this export."
        } else {
            return "Enable to create a waveform visual when no video exists."
        }
    }

    private var dateTagHelperText: String {
        file.includeDateTag ? "Adds 'Date generated' to the metadata comment." : "Toggle to stamp the export date into metadata."
    }

    private func iconToggleLabel(
        systemName: String,
        isActive: Bool,
        disabled: Bool,
        activeColor: Color = .accentColor,
        size: CGFloat = 40,
        cornerRadius: CGFloat = 10,
        tintForegroundWhenActive: Bool = true
    ) -> some View {
        let foreground: Color
        if disabled {
            foreground = Color.gray.opacity(0.5)
        } else if isActive && tintForegroundWhenActive {
            foreground = activeColor
        } else {
            foreground = .primary
        }

        let background = disabled
            ? Color.gray.opacity(0.12)
            : (isActive ? activeColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))

        let borderColor = disabled
            ? Color.gray.opacity(0.2)
            : (isActive ? activeColor.opacity(0.6) : Color.gray.opacity(0.25))

        return Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isActive ? 0.15 : 0.05), radius: isActive ? 4 : 1, x: 0, y: 1)
    }
    
    private var progressText: String {
        if file.isLiveStreamRecording {
            var parts: [String] = ["Recording live stream"]

            // Add duration if available
            if let duration = file.liveRecordingDuration, duration > 0 {
                let minutes = Int(duration) / 60
                let seconds = Int(duration) % 60
                parts.append(String(format: "%d:%02d", minutes, seconds))
            }

            // Add file size if available
            if let fileSize = file.liveRecordingFileSize, fileSize > 0 {
                parts.append(formatFileSize(fileSize))
            }

            // Add speed if available
            if let speed = file.downloadSpeed {
                parts.append(speed)
            }

            return parts.joined(separator: " • ")
        }
        // Handle download states first
        if file.isDownloading {
            if isDownloadPreparing {
                return "Preparing for download..."
            }
            if let speed = file.downloadSpeed {
                return "Downloading... \(speed)"
            } else {
                return "Downloading..."
            }
        }
        if let scheduledTime = file.scheduledDownloadTime {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            formatter.timeZone = .current  // Explicitly use local timezone
            let timeString = formatter.string(from: scheduledTime)
            return "Scheduled for \(timeString)"
        }
        if file.fileAlreadyExistsPath != nil {
            return "File already exists - click to redownload"
        }
        if let error = file.downloadError {
            return "Download failed: \(error)"
        }

        switch file.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = file.eta {
                return "Converting... ETA: \(eta)"
            } else {
                return "Converting..."
            }
        case .done:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        if file.isLiveStreamRecording {
            return .red
        }
        // Handle download states first
        if file.isDownloading {
            return .purple
        }
        if file.scheduledDownloadTime != nil {
            return .cyan
        }
        if file.fileAlreadyExistsPath != nil {
            return .orange
        }
        if file.downloadError != nil {
            return .red
        }

        switch file.status {
        case .done: return .green
        case .converting: return .blue
        case .cancelled: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    @ViewBuilder
    private var liveRecordingBadge: some View {
        if file.isLiveStreamRecording {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                Text("Live")
                    .font(.caption2)
            }
            .foregroundColor(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var isDownloadPreparing: Bool {
        file.isDownloading && !file.downloadHasProgress
    }

    private var isSubtitlePreparing: Bool {
        switch file.subtitleStatus {
        case .pending, .extractingAudio:
            return true
        default:
            return false
        }
    }

    /// Progress bar value (0.0 to 1.0) based on current state
    private var progressBarValue: Double {
        if file.uploadStatus == .uploading {
            return file.uploadProgress
        } else if file.isDownloading {
            return file.downloadProgress
        } else if file.status == .converting {
            return file.progress
        } else if file.subtitleStatus.isInProgress {
            return file.subtitleProgress
        } else {
            return file.progress
        }
    }

    /// Progress bar color based on current state
    private var progressBarColor: Color {
        if file.isLiveStreamRecording {
            return .red
        }
        if file.uploadStatus == .uploading {
            return .orange
        } else if file.isDownloading {
            return .purple
        } else if file.status == .converting {
            return .accentColor
        } else if file.subtitleStatus.isInProgress {
            return .green
        } else {
            return .accentColor
        }
    }

    private var downloadActionColor: Color {
        file.isLiveStreamRecording ? .red : .purple
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func displayOutputFilename() -> String {
        if let overrideName = sanitizedOutputNameOverride() {
            let resolvedExtension = preset.outputExtension(for: file.url)
            return overrideName + "." + resolvedExtension
        }
        if let outputURL = file.outputURL {
            return outputURL.lastPathComponent
        }
        return generateOutputFilename(from: file.name)
    }

    private func generateOutputFilename(from input: String) -> String {
        let filename = (input as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(filename)
        let resolvedExtension = preset.outputExtension(for: file.url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        return "\(sanitized)\(suffixPart).\(resolvedExtension)"
    }

    private func sanitizedOutputNameOverride() -> String? {
        guard let raw = file.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return FileNameProcessor.processFileName(raw)
    }

    private func beginOutputNameEdit() {
        outputNameDraft = displayOutputFilename()
        isEditingOutputName = true
        isOutputNameFieldFocused = true
    }

    private func commitOutputNameEdit() {
        isEditingOutputName = false
        let trimmed = outputNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameOutputFileName?(trimmed.isEmpty ? nil : trimmed)
    }

    private func cancelOutputNameEdit() {
        isEditingOutputName = false
        outputNameDraft = ""
    }

    private func dragIcon(for outputURL: URL, color: Color, helpText: String) -> some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .foregroundColor(color)
            .help(helpText)
            .onDrag {
                let provider = NSItemProvider(object: outputURL as NSURL)
                provider.suggestedName = outputURL.lastPathComponent
                return provider
            }
    }
}

struct VideoFileRowView_Previews: PreviewProvider {
    struct Preview: View {
        @State private var item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video.mp4"),
            name: "Sample Video",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: nil,
            comment: "This is a sample comment"
        )
        @State private var focusedCommentID: UUID?
        
        var body: some View {
            VideoFileRowView(
                file: $item,
                focusedCommentID: $focusedCommentID,
                preset: .videoLoop,
                onCancel: {},
                onDelete: {},
                onReset: { _ in }
            )
            .frame(width: 800, height: 150)
            .padding()
        }
    }

    static var previews: some View {
        Preview()
    }
}

// MARK: - File Reset Button with Option Key Support

private struct FileResetButton: View {
    let isEnabled: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    var body: some View {
        FileResetButtonNSViewWrapper(
            isEnabled: isEnabled,
            onReset: onReset
        )
    }
}

private struct FileResetButtonNSViewWrapper: NSViewRepresentable {
    let isEnabled: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset")
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.isEnabled = isEnabled

        // Update appearance
        if isEnabled {
            nsView.contentTintColor = .systemBlue
        } else {
            nsView.contentTintColor = .systemGray
        }

        // Update tooltip based on settings
        let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
        if resetClearsSettings {
            nsView.toolTip = "Reset item (clears trim, crop, audio routing). Hold Option to only reset status."
        } else {
            nsView.toolTip = "Reset item to waiting status. Hold Option to also clear trim, crop, and audio routing."
        }

        context.coordinator.onReset = onReset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReset: onReset)
    }

    class Coordinator: NSObject {
        var onReset: (_ optionKeyPressed: Bool) -> Void

        init(onReset: @escaping (_ optionKeyPressed: Bool) -> Void) {
            self.onReset = onReset
        }

        @objc func buttonClicked(_ sender: NSButton) {
            let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
            onReset(optionKeyPressed)
        }
    }
}

struct VideoFileRowView_Previews2: PreviewProvider {
    struct Preview: View {
        @State private var item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video2.mp4"),
            name: "Sample Video 2",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .converting,
            progress: 0.3,
            eta: "00:01:23",
            outputURL: nil,
            comment: "This is another sample comment"
        )
        @State private var focusedCommentID: UUID?
        
        var body: some View {
            VideoFileRowView(
                file: $item,
                focusedCommentID: $focusedCommentID,
                preset: .videoLoop,
                onCancel: {},
                onDelete: {},
                onReset: { _ in }
            )
            .frame(width: 800, height: 150)
            .padding()
        }
    }

    static var previews: some View {
        Preview()
    }
}

// MARK: - Comment Preview Popover for Row

private struct CommentPreviewPopoverView: View {
    let comment: String
    let includeDateTag: Bool
    
    private var commentPrefix: String {
        UserDefaults.standard.string(forKey: AppConstants.commentPrefixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private var commentSuffix: String {
        UserDefaults.standard.string(forKey: AppConstants.commentSuffixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private var commentSeparator: String {
        UserDefaults.standard.string(forKey: AppConstants.commentSeparatorKey) ?? AppConstants.defaultCommentSeparator
    }
    
    private var commentDateFormat: String {
        UserDefaults.standard.string(forKey: AppConstants.commentDateFormatKey) ?? AppConstants.defaultCommentDateFormat
    }
    
    private var dateTagPrefix: String {
        let prefix = UserDefaults.standard.string(forKey: AppConstants.dateTagPrefixKey) ?? AppConstants.defaultDateTagPrefix
        return prefix.isEmpty ? AppConstants.defaultDateTagPrefix : prefix
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Metadata Comment Preview")
                .font(.headline)
            
            Text("This comment will be embedded in the exported file's metadata.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                if includeDateTag {
                    componentRow(label: "Date tag:", value: dateTagValue, color: .primary)
                }
                if !commentPrefix.isEmpty {
                    componentRow(label: "Prefix:", value: commentPrefix, color: .primary)
                }
                componentRow(label: "Comment:", value: comment.isEmpty ? "(empty)" : comment, color: comment.isEmpty ? .secondary : .primary)
                if !commentSuffix.isEmpty {
                    componentRow(label: "Suffix:", value: commentSuffix, color: .primary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Full output:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(buildFullComment())
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            
            Divider()
            
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Change prefix, suffix, separator, and date format in Settings > General.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 420)
    }
    
    private var dateTagValue: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = commentDateFormat
        return "\(dateTagPrefix): \(dateFormatter.string(from: Date()))"
    }
    
    private func componentRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func buildFullComment() -> String {
        var parts: [String] = []
        
        if includeDateTag {
            parts.append(dateTagValue)
        }
        
        if !commentPrefix.isEmpty {
            parts.append(commentPrefix)
        }
        
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            parts.append(trimmedComment)
        }
        
        if !commentSuffix.isEmpty {
            parts.append(commentSuffix)
        }
        
        if parts.isEmpty {
            return "(no comment will be added)"
        }
        
        return parts.joined(separator: commentSeparator)
    }
}
