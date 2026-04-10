// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension VideoFileCellView {

    // MARK: - Badge Setup

    func setupBadges() {
        let badges: [(BadgeView, NSLayoutConstraint.Attribute, NSLayoutConstraint.Attribute)] = [
            (audioRoutingBadge, .leading, .top),
            (timecodeBadge, .trailing, .top),
            (trimBadge, .leading, .bottom),
            (cropBadge, .trailing, .bottom),
            (uploadBadge, .trailing, .centerY),
            (analyticsBadgeView, .leading, .centerY),
        ]

        for (badge, hAttr, vAttr) in badges {
            thumbnailContainer.addSubview(badge)
            let hConst: CGFloat = (hAttr == .leading) ? 4 : -4
            let vConst: CGFloat = (vAttr == .top) ? 4 : (vAttr == .bottom) ? -4 : 0
            NSLayoutConstraint.activate([
                NSLayoutConstraint(item: badge, attribute: hAttr, relatedBy: .equal, toItem: thumbnailContainer, attribute: hAttr, multiplier: 1, constant: hConst),
                NSLayoutConstraint(item: badge, attribute: vAttr, relatedBy: .equal, toItem: thumbnailContainer, attribute: vAttr, multiplier: 1, constant: vConst),
            ])
        }
    }

    // MARK: - Hover Overlay

    func setupHoverOverlay() {
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        hoverOverlay.alphaValue = 0
        hoverOverlay.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(hoverOverlay)

        NSLayoutConstraint.activate([
            hoverOverlay.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            hoverOverlay.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            hoverOverlay.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            hoverOverlay.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),
        ])

        // Hover buttons
        let previewBtn = makeHoverButton(symbol: "eye", tooltip: "Preview / Trim", action: #selector(hoverPreviewClicked), size: 18)
        let playBtn = makeHoverButton(symbol: "play.fill", tooltip: "Play Fullscreen", action: #selector(hoverPlayClicked), size: 40)
        let metadataBtn = makeHoverButton(symbol: "info.circle", tooltip: "Metadata", action: #selector(hoverMetadataClicked), size: 18)
        let audioBtn = makeHoverButton(symbol: "speaker.wave.2", tooltip: "Audio Routing", action: #selector(hoverAudioClicked), size: 16)
        let timecodeBtn = makeHoverButton(symbol: "timer", tooltip: "Timecode", action: #selector(hoverTimecodeClicked), size: 16)

        // Position buttons manually for precise centering
        for btn in [previewBtn, playBtn, metadataBtn, audioBtn, timecodeBtn] {
            hoverOverlay.addSubview(btn)
        }

        NSLayoutConstraint.activate([
            // Top row: audio (top-left), timecode (top-right)
            audioBtn.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: 8),
            audioBtn.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: 6),
            timecodeBtn.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -8),
            timecodeBtn.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: 6),

            // Center: play button
            playBtn.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
            playBtn.centerYAnchor.constraint(equalTo: hoverOverlay.centerYAnchor),

            // Bottom row: preview (bottom-left), metadata (bottom-right)
            previewBtn.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: 8),
            previewBtn.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -6),
            metadataBtn.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -8),
            metadataBtn.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -6),
        ])
    }

    private func makeHoverButton(symbol: String, tooltip: String, action: Selector, size: CGFloat = 16) -> NSButton {
        let btn = NSButton()
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        btn.contentTintColor = .white
        btn.isBordered = false
        btn.target = self
        btn.action = action
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    @objc private func hoverPreviewClicked() { actionHandler?(.showPreview) }
    @objc private func hoverPlayClicked() { actionHandler?(.playFullscreen) }
    @objc private func hoverMetadataClicked() { actionHandler?(.showMetadata) }
    @objc private func hoverAudioClicked() { actionHandler?(.showAudioRouting) }
    @objc private func hoverTimecodeClicked() { actionHandler?(.showTimecode) }

    // MARK: - Tracking Area (hover detection)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            thumbnailContainer.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: thumbnailContainer.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        thumbnailContainer.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hoverOverlay.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hoverOverlay.animator().alphaValue = 0
        }
    }

    // MARK: - Update Badges

    func updateBadges(config: VideoFileCellConfiguration) {
        // Audio routing badge
        if config.isMuted {
            audioRoutingBadge.update(icon: "speaker.slash.fill", text: "", color: .systemRed)
        } else if config.hasCustomAudioRouting {
            if config.hasDownmix {
                audioRoutingBadge.update(icon: "hifispeaker.2", text: "→2ch", color: .systemGreen)
            } else if config.hasOutputSurroundWithoutDownmix {
                audioRoutingBadge.update(icon: "speaker.wave.3.fill", text: "\(config.audioTrackCount)", color: .systemOrange)
            } else {
                audioRoutingBadge.update(icon: "hifispeaker.2", text: "\(config.audioTrackCount)")
            }
        } else if config.hasSurroundAudio {
            audioRoutingBadge.update(icon: "speaker.wave.3.fill", text: "", color: .systemOrange)
        } else {
            audioRoutingBadge.hide()
        }

        // Trim badge
        if config.hasTrim {
            let secs = config.trimmedDuration
            let mins = Int(secs) / 60
            let secsRemainder = Int(secs) % 60
            let durationStr = mins > 0 ? "\(mins)m\(secsRemainder)s" : "\(secsRemainder)s"
            trimBadge.update(icon: "scissors", text: durationStr)
        } else {
            trimBadge.hide()
        }

        // Crop badge
        if config.hasCrop {
            cropBadge.update(icon: "crop", text: "\(config.cropPercentage)%")
        } else {
            cropBadge.hide()
        }

        // Timecode badge
        if let mode = config.timecodeMode {
            timecodeBadge.update(icon: "timer", text: mode)
        } else {
            timecodeBadge.hide()
        }

        // Upload badge
        switch config.uploadStatus {
        case .uploading:
            uploadBadge.update(icon: "arrow.up.circle.fill", text: "\(Int(config.uploadProgress * 100))%", color: .systemBlue)
        case .uploaded:
            uploadBadge.update(icon: "checkmark.circle.fill", text: "", color: .systemGreen)
        case .failed(_):
            uploadBadge.update(icon: "exclamationmark.circle.fill", text: "", color: .systemRed)
        case .pending:
            uploadBadge.update(icon: "clock.fill", text: "", color: .systemCyan)
        default:
            if config.uploadEnabled {
                uploadBadge.update(icon: "icloud.and.arrow.up", text: "", color: .white)
            } else {
                uploadBadge.hide()
            }
        }

        // Analytics badge
        if config.hasAnalyticsResults {
            analyticsBadgeView.update(icon: "chart.bar.xaxis.ascending", text: "", color: .systemGreen)
        } else if config.analyticsStatus.isInProgress {
            analyticsBadgeView.update(icon: "chart.bar.xaxis.ascending", text: "\(Int(config.analyticsProgress * 100))%", color: .systemOrange)
        } else if config.analyticsEnabled {
            analyticsBadgeView.update(icon: "chart.bar.xaxis", text: "", color: .systemCyan)
        } else {
            analyticsBadgeView.hide()
        }
    }
}
