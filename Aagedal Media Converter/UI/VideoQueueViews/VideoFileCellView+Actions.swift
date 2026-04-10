// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension VideoFileCellView {

    // MARK: - Toggle Buttons Update

    func updateToggleButtons(config: VideoFileCellConfiguration) {
        // Auto-encode button (only during download)
        let showAutoEncode = config.isDownloading || config.scheduledDownloadTime != nil
        autoEncodeButton.isHidden = !showAutoEncode || config.isCompactMode
        if showAutoEncode {
            autoEncodeButton.image = NSImage(systemSymbolName: config.autoEncodeAfterDownload ? "play.fill" : "play", accessibilityDescription: nil)
            autoEncodeButton.contentTintColor = config.autoEncodeAfterDownload ? .systemGreen : .secondaryLabelColor
        }

        // Upload button
        uploadButton.isHidden = config.isCompactMode
        let uploadIcon: String
        let uploadColor: NSColor
        if config.uploadSourceFile {
            uploadIcon = "arrow.up.doc.fill"
            uploadColor = .systemOrange
        } else if config.uploadEnabled {
            uploadIcon = "icloud.and.arrow.up.fill"
            uploadColor = .systemBlue
        } else {
            uploadIcon = "icloud.and.arrow.up"
            uploadColor = .secondaryLabelColor
        }
        uploadButton.image = NSImage(systemSymbolName: uploadIcon, accessibilityDescription: nil)
        uploadButton.contentTintColor = uploadColor
        uploadButton.isEnabled = config.isUploadConfigured

        // Transcription button
        transcriptionButton.isHidden = config.isCompactMode
        let isTranscriptionEnabled = config.subtitleEnabled && (config.subtitleMethod == .whisper || config.subtitleMethod == .parakeet)
        transcriptionButton.image = NSImage(systemSymbolName: isTranscriptionEnabled ? "captions.bubble.fill" : "captions.bubble", accessibilityDescription: nil)
        if !config.isTranscriptionAvailable {
            transcriptionButton.contentTintColor = .systemOrange
        } else if isTranscriptionEnabled {
            transcriptionButton.contentTintColor = .systemGreen
        } else {
            transcriptionButton.contentTintColor = .secondaryLabelColor
        }

        // OCR button
        let showOCR = config.hasBitmapSubtitles && !config.isCompactMode
        ocrButton.isHidden = !showOCR
        if showOCR {
            let isOCREnabled = config.subtitleEnabled && config.subtitleMethod == .ocr
            ocrButton.contentTintColor = isOCREnabled ? .systemGreen : .secondaryLabelColor
        }

        // Analytics button
        let showAnalytics = config.hasVideoStream && !config.isCompactMode
        analyticsButton.isHidden = !showAnalytics
        if showAnalytics {
            let analyticsIcon: String
            let analyticsColor: NSColor
            if config.hasAnalyticsResults {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemGreen
            } else if config.analyticsStatus.isInProgress {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemOrange
            } else if config.analyticsEnabled {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemCyan
            } else {
                analyticsIcon = "chart.bar.xaxis"
                analyticsColor = .secondaryLabelColor
            }
            analyticsButton.image = NSImage(systemSymbolName: analyticsIcon, accessibilityDescription: nil)
            analyticsButton.contentTintColor = analyticsColor
        }
    }

    // MARK: - Action Buttons Update

    func updateActionButtons(config: VideoFileCellConfiguration) {
        // Hide all first
        deleteButton.isHidden = true
        resetButton.isHidden = true
        cancelButton.isHidden = true
        stopDownloadButton.isHidden = true
        cancelDownloadButton.isHidden = true
        cancelScheduledButton.isHidden = true
        retryDownloadButton.isHidden = true
        redownloadButton.isHidden = true
        cancelSubtitleButton.isHidden = true
        cancelAnalyticsButton.isHidden = true

        if config.isDownloading {
            stopDownloadButton.isHidden = false
            cancelDownloadButton.isHidden = false
        } else if config.scheduledDownloadTime != nil {
            cancelScheduledButton.isHidden = false
        } else if config.fileAlreadyExistsPath != nil {
            redownloadButton.isHidden = false
        } else if config.downloadError != nil {
            retryDownloadButton.isHidden = false
        } else if config.status == .converting {
            cancelButton.isHidden = false
        } else if config.subtitleStatus.isInProgress {
            cancelSubtitleButton.isHidden = false
        } else if config.analyticsStatus.isInProgress {
            cancelAnalyticsButton.isHidden = false
        } else {
            deleteButton.isHidden = false
            resetButton.isHidden = false
            resetButton.isEnabled = config.status != .converting && config.status != .waiting
        }
    }

    // MARK: - Status Row Update

    func updateStatusRow(config: VideoFileCellConfiguration) {
        // Overwrite warning
        overwriteWarningLabel.isHidden = config.isCompactMode || !(config.status == .waiting && config.outputFileExists)

        // Output size
        if !config.isCompactMode, config.status == .done, let size = config.formattedOutputSize {
            outputSizeLabel.stringValue = "Export: \(size)"
            outputSizeLabel.isHidden = false
        } else {
            outputSizeLabel.isHidden = true
        }

        // Status text
        statusLabel.stringValue = progressText(config: config)
        statusLabel.textColor = statusColor(config: config)
    }

    // MARK: - Progress Text

    private func progressText(config: VideoFileCellConfiguration) -> String {
        // Scheduled download
        if let scheduledTime = config.scheduledDownloadTime {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Scheduled for \(formatter.string(from: scheduledTime))"
        }

        // Downloading
        if config.isDownloading {
            if config.downloadStopping { return "Stopping..." }
            if config.isLiveStreamRecording { return "Recording live stream..." }
            if !config.downloadHasProgress { return "Preparing download..." }
            let pct = Int(config.downloadProgress * 100)
            if let speed = config.downloadSpeed {
                return "Downloading: \(pct)% (\(speed))"
            }
            return "Downloading: \(pct)%"
        }

        // Download error
        if let error = config.downloadError {
            return "Download failed: \(error)"
        }

        // File already exists (download skip)
        if config.fileAlreadyExistsPath != nil {
            return "File already exists"
        }

        // Upload
        if config.uploadStatus == .uploading {
            let pct = Int(config.uploadProgress * 100)
            return "Uploading: \(pct)%"
        }
        if config.uploadStatus == .uploaded {
            return "Upload complete"
        }
        if case .failed = config.uploadStatus {
            return "Upload failed"
        }

        // Subtitle generation
        if config.subtitleStatus.isInProgress {
            let pct = Int(config.subtitleProgress * 100)
            return "Generating subtitles: \(pct)%"
        }

        // Analytics
        if config.analyticsStatus.isInProgress {
            let pct = Int(config.analyticsProgress * 100)
            return "Analyzing quality: \(pct)%"
        }

        // Conversion status
        switch config.status {
        case .waiting:
            return "Waiting"
        case .converting:
            let pct = Int(config.progress * 100)
            if let eta = config.eta {
                return "Converting: \(pct)% — ETA \(eta)"
            }
            return "Converting: \(pct)%"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        @unknown default:
            return ""
        }
    }

    // MARK: - Status Color

    private func statusColor(config: VideoFileCellConfiguration) -> NSColor {
        if config.downloadError != nil { return .systemRed }
        if config.fileAlreadyExistsPath != nil { return .systemOrange }
        if config.isDownloading { return .systemPurple }
        if config.uploadStatus == .uploading { return .systemBlue }
        if config.uploadStatus == .uploaded { return .systemGreen }
        if case .failed = config.uploadStatus { return .systemRed }
        if config.subtitleStatus.isInProgress { return .systemOrange }
        if config.analyticsStatus.isInProgress { return .systemCyan }

        switch config.status {
        case .waiting: return .secondaryLabelColor
        case .converting: return .systemBlue
        case .done: return .systemGreen
        case .failed: return .systemRed
        @unknown default: return .secondaryLabelColor
        }
    }

    // MARK: - Context Menu

    func buildContextMenu(config: VideoFileCellConfiguration) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Show Source in Finder", action: #selector(ctxShowInFinder), keyEquivalent: "")
            .target = self

        if config.status == .done, config.outputURL != nil {
            menu.addItem(withTitle: "Show Output in Finder", action: #selector(ctxShowOutputInFinder), keyEquivalent: "")
                .target = self
        }

        if config.subtitleFilePath != nil {
            menu.addItem(withTitle: "Show Subtitle File in Finder", action: #selector(ctxShowSubtitleInFinder), keyEquivalent: "")
                .target = self
        }

        menu.addItem(.separator())

        if !config.isDownloading && config.scheduledDownloadTime == nil {
            menu.addItem(withTitle: "Preview / Trim", action: #selector(ctxPreview), keyEquivalent: "")
                .target = self
        }

        menu.addItem(withTitle: "Metadata", action: #selector(ctxMetadata), keyEquivalent: "")
            .target = self

        if config.hasVideoStream || config.audioStreamCount > 0 {
            menu.addItem(withTitle: "Audio Routing", action: #selector(ctxAudioRouting), keyEquivalent: "")
                .target = self
        }

        menu.addItem(withTitle: "Attach Subtitle File", action: #selector(ctxAttachSubtitle), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let renameItem = menu.addItem(withTitle: "Rename Output", action: #selector(ctxRename), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = config.status == .waiting

        let resetItem = menu.addItem(withTitle: "Reset", action: #selector(ctxReset), keyEquivalent: "")
        resetItem.target = self
        resetItem.isEnabled = config.status != .waiting && config.status != .converting

        let removeItem = menu.addItem(withTitle: "Remove", action: #selector(ctxRemove), keyEquivalent: "")
        removeItem.target = self
        removeItem.isEnabled = config.status != .converting

        return menu
    }

    @objc private func ctxShowInFinder() { actionHandler?(.showInFinder) }
    @objc private func ctxShowOutputInFinder() { actionHandler?(.showOutputInFinder) }
    @objc private func ctxShowSubtitleInFinder() { actionHandler?(.showSubtitleInFinder) }
    @objc private func ctxPreview() { actionHandler?(.showPreview) }
    @objc private func ctxMetadata() { actionHandler?(.showMetadata) }
    @objc private func ctxAudioRouting() { actionHandler?(.showAudioRouting) }
    @objc private func ctxAttachSubtitle() { actionHandler?(.attachSubtitleFile) }
    @objc private func ctxRename() { actionHandler?(.beginRename) }
    @objc private func ctxReset() { actionHandler?(.reset(optionKeyPressed: false)) }
    @objc private func ctxRemove() { actionHandler?(.delete) }
}
