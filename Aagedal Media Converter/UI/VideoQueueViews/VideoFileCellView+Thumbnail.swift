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

        // Set corner anchors so each badge scales toward its corner
        audioRoutingBadge.cornerAnchor = CGPoint(x: 0, y: 1)    // top-left
        timecodeBadge.cornerAnchor = CGPoint(x: 1, y: 1)        // top-right
        trimBadge.cornerAnchor = CGPoint(x: 0, y: 0)            // bottom-left
        cropBadge.cornerAnchor = CGPoint(x: 1, y: 0)            // bottom-right
        // Wire up badge click actions
        audioRoutingBadge.onClick = { [weak self] in self?.actionHandler?(.showAudioRouting) }
        timecodeBadge.onClick = { [weak self] in self?.actionHandler?(.showTimecode) }
        trimBadge.onClick = { [weak self] in self?.actionHandler?(.showPreview) }
        cropBadge.onClick = { [weak self] in self?.actionHandler?(.showPreview) }
    }

    // MARK: - Overlay Action Buttons (shown on hover)

    func setupOverlayButtons() {
        // These are always-available action buttons, shown only on hover.
        // Added after badges so they render on top.

        // Play button — center
        overlayPlayButton.update(icon: "play.fill", text: "")
        overlayPlayButton.isHidden = true
        overlayPlayButton.onClick = { [weak self] in self?.actionHandler?(.playFullscreen) }
        thumbnailContainer.addSubview(overlayPlayButton)
        NSLayoutConstraint.activate([
            overlayPlayButton.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            overlayPlayButton.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
        ])

        // Trim button — bottom left
        overlayTrimButton.update(icon: "scissors", text: "Trim")
        overlayTrimButton.isHidden = true
        overlayTrimButton.onClick = { [weak self] in self?.actionHandler?(.showPreview) }
        thumbnailContainer.addSubview(overlayTrimButton)
        NSLayoutConstraint.activate([
            overlayTrimButton.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: 4),
            overlayTrimButton.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -4),
        ])

        // Metadata button — bottom right
        overlayMetadataButton.update(icon: "info.circle", text: "Info")
        overlayMetadataButton.isHidden = true
        overlayMetadataButton.onClick = { [weak self] in self?.actionHandler?(.showMetadata) }
        thumbnailContainer.addSubview(overlayMetadataButton)
        NSLayoutConstraint.activate([
            overlayMetadataButton.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -4),
            overlayMetadataButton.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -4),
        ])
    }

    private var overlayButtons: [BadgeView] {
        [overlayPlayButton, overlayTrimButton, overlayMetadataButton]
    }

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

    private var allBadges: [BadgeView] {
        [audioRoutingBadge, timecodeBadge, trimBadge, cropBadge]
    }

    override func mouseEntered(with event: NSEvent) {
        for badge in allBadges {
            badge.showHoverOutline()
        }
        for button in overlayButtons {
            button.isHidden = false
            button.showHoverOutline()
        }
    }

    override func mouseExited(with event: NSEvent) {
        for badge in allBadges {
            badge.hideHoverOutline()
        }
        for button in overlayButtons {
            button.isHidden = true
            button.hideHoverOutline()
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

        uploadBadge.hide()
        analyticsBadgeView.hide()
    }
}
