// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension VideoFileCellView {

    // MARK: - Badge Setup

    func setupBadges() {
        // The bottom-right slot is owned by `overlayInfoButton` (metadata), configured
        // in `setupOverlayButtons`. The crop badge used to live there but duplicated
        // the trim badge's role as a "tap to open the trim view" entry point, so the
        // trim badge at bottom-left is now the single gateway to that view.
        let badges: [(BadgeView, NSLayoutConstraint.Attribute, NSLayoutConstraint.Attribute)] = [
            (audioRoutingBadge, .leading, .top),
            (timecodeBadge, .trailing, .top),
            (trimBadge, .leading, .bottom),
        ]

        for (badge, hAttr, vAttr) in badges {
            thumbnailContainer.addSubview(badge)
            let hConst: CGFloat = (hAttr == .leading) ? 6 : -6
            let vConst: CGFloat = (vAttr == .top) ? 6 : (vAttr == .bottom) ? -6 : 0
            NSLayoutConstraint.activate([
                NSLayoutConstraint(item: badge, attribute: hAttr, relatedBy: .equal, toItem: thumbnailContainer, attribute: hAttr, multiplier: 1, constant: hConst),
                NSLayoutConstraint(item: badge, attribute: vAttr, relatedBy: .equal, toItem: thumbnailContainer, attribute: vAttr, multiplier: 1, constant: vConst),
            ])
        }

        // Wire up badge click actions
        audioRoutingBadge.onClick = { [weak self] in self?.actionHandler?(.showAudioRouting) }
        timecodeBadge.onClick = { [weak self] in self?.actionHandler?(.showTimecode) }
        trimBadge.onClick = { [weak self] in self?.actionHandler?(.showPreview) }
    }

    // MARK: - Overlay Buttons (shown on hover)

    func setupOverlayButtons() {
        // Play button — centered, revealed on hover.
        overlayPlayButton.isHidden = true
        overlayPlayButton.onClick = { [weak self] in self?.actionHandler?(.playFullscreen) }
        thumbnailContainer.addSubview(overlayPlayButton)
        NSLayoutConstraint.activate([
            overlayPlayButton.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            overlayPlayButton.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
        ])

        // Info button — anchored to the bottom-right corner as the always-visible
        // counterpart to the trim badge at bottom-left. Clicking opens metadata.
        overlayInfoButton.update(icon: "info.circle", text: "")
        overlayInfoButton.onClick = { [weak self] in self?.actionHandler?(.showMetadata) }
        thumbnailContainer.addSubview(overlayInfoButton)
        NSLayoutConstraint.activate([
            overlayInfoButton.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -6),
            overlayInfoButton.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - Tracking Area (hover detection)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if Self.thumbnailAreaEnabled {
            if let existing = trackingArea {
                thumbnailContainer.removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: thumbnailContainer.bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: ["kind": "thumbnail"]
            )
            thumbnailContainer.addTrackingArea(area)
            trackingArea = area
        }

        // Tracking area covering the duration + file-size labels so the cell can
        // draw an underline on hover and show a pointing-hand cursor.
        if let existing = durationSizeTracker {
            removeTrackingArea(existing)
            durationSizeTracker = nil
        }
        if !durationLabel.isHidden && !sizeLabel.isHidden {
            let durationRect = durationLabel.convert(durationLabel.bounds, to: self)
            let sizeRect = sizeLabel.convert(sizeLabel.bounds, to: self)
            let unionRect = durationRect.union(sizeRect)
            if unionRect.width > 0 && unionRect.height > 0 {
                let area = NSTrackingArea(
                    rect: unionRect,
                    options: [.mouseEnteredAndExited, .activeInActiveApp],
                    owner: self,
                    userInfo: ["kind": "durationSize"]
                )
                addTrackingArea(area)
                durationSizeTracker = area
            }
        }
    }

    private var allBadges: [BadgeView] {
        [audioRoutingBadge, timecodeBadge, trimBadge, overlayInfoButton]
    }

    override func mouseEntered(with event: NSEvent) {
        let kind = (event.trackingArea?.userInfo?["kind"] as? String) ?? "thumbnail"
        switch kind {
        case "durationSize":
            setDurationSizeHovered(true)
        default:
            overlayPlayButton.setHovered(true)
            for badge in allBadges where !badge.isHidden {
                badge.setHovered(true)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let kind = (event.trackingArea?.userInfo?["kind"] as? String) ?? "thumbnail"
        switch kind {
        case "durationSize":
            setDurationSizeHovered(false)
        default:
            overlayPlayButton.setHovered(false)
            for badge in allBadges {
                badge.setHovered(false)
            }
        }
    }

    // MARK: - Duration / file-size hover underline

    /// Updates `durationLabel` + `sizeLabel` to show an underline on hover and
    /// switches the cursor to the pointing hand so the text reads as clickable.
    /// The click itself is handled in `mouseDown` in the main file — it routes
    /// to `.showMetadata`.
    func setDurationSizeHovered(_ hovered: Bool) {
        guard isDurationSizeHovered != hovered else { return }
        isDurationSizeHovered = hovered
        applyDurationSizeUnderline(durationLabel, hovered: hovered)
        applyDurationSizeUnderline(sizeLabel, hovered: hovered)
        if hovered {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// Re-applies the hover underline if the cursor is still over the duration/size
    /// area — `configure()` sets `stringValue` directly, which wipes any
    /// `attributedStringValue` attributes.
    func refreshDurationSizeHoverStyle() {
        guard isDurationSizeHovered else { return }
        applyDurationSizeUnderline(durationLabel, hovered: true)
        applyDurationSizeUnderline(sizeLabel, hovered: true)
    }

    private func applyDurationSizeUnderline(_ label: NSTextField, hovered: Bool) {
        let text = label.stringValue
        guard !text.isEmpty else { return }
        if hovered {
            var attrs: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let font = label.font { attrs[.font] = font }
            if let color = label.textColor { attrs[.foregroundColor] = color }
            label.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
        } else {
            // Reassign stringValue clears attributedStringValue and restores default rendering.
            label.stringValue = text
        }
    }

    // MARK: - Update Badges

    func updateBadges(config: VideoFileCellConfiguration) {
        // Audio routing badge — always visible (when the item has audio) so the
        // routing popover is reachable from the thumbnail even for plain stereo
        // sources with default routing. Mirrors the always-visible pattern used
        // by the timecode and trim badges.
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
        } else if config.audioStreamCount > 0 {
            // Default stereo (or single-track) audio with no overrides.
            audioRoutingBadge.update(icon: "speaker.wave.2.fill", text: "", color: .white)
        } else {
            // No audio streams at all — nothing to route.
            audioRoutingBadge.hide()
        }

        // Trim badge — always visible so it doubles as the "enter trim mode" button.
        // Shows just the scissors icon when no trim is set; adds the trimmed duration
        // once the user sets trim points.
        if config.hasTrim {
            let secs = config.trimmedDuration
            let mins = Int(secs) / 60
            let secsRemainder = Int(secs) % 60
            let durationStr = mins > 0 ? "\(mins)m\(secsRemainder)s" : "\(secsRemainder)s"
            trimBadge.update(icon: "scissors", text: durationStr, color: .systemOrange)
        } else {
            trimBadge.update(icon: "scissors", text: "")
        }

        // cropBadge is no longer placed on the thumbnail; keep it hidden so the
        // retained property doesn't render stale state if it ever gets added back.
        cropBadge.hide()

        // Timecode badge — icon-only. Color encodes the source:
        //   SRC (source timecode) → blue
        //   MAN (manual override) → orange
        //   No TC → white with a diagonal slash across the glyph
        switch config.timecodeMode {
        case "SRC":
            timecodeBadge.update(icon: "timer", text: "", color: .systemBlue)
        case "MAN":
            timecodeBadge.update(icon: "timer", text: "", color: .systemOrange)
        case "No TC":
            timecodeBadge.update(icon: "timer", text: "", color: .white, slashed: true)
        default:
            timecodeBadge.hide()
        }

        uploadBadge.hide()
        analyticsBadgeView.hide()
    }
}
