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

        // Tracking area covering every clickable metadata label — duration,
        // size, video format (resolution · fps), output size. Any of them
        // opens the metadata window on click, so all should show the
        // underline + pointing-hand cursor on hover.
        //
        // Attach to `infoStack` with `.inVisibleRect` so the rect auto-tracks
        // the stack's bounds — `videoFormatLabel` and `outputSizeLabel` are
        // hidden until their data is ready, and the stack reflows when they
        // appear. A static rect computed at initial layout would only cover
        // the labels that were already visible.
        if let existing = durationSizeTracker {
            infoStack.removeTrackingArea(existing)
            durationSizeTracker = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: ["kind": "durationSize"]
        )
        infoStack.addTrackingArea(area)
        durationSizeTracker = area
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

    // MARK: - Metadata-label hover underline

    /// Labels that open the metadata window when clicked — kept in one place so
    /// the hover style and hit-test stay in sync.
    private var metadataHoverLabels: [NSTextField] {
        [durationLabel, sizeLabel, videoFormatLabel, outputSizeLabel]
    }

    /// Applies an underline + pointing-hand cursor on hover to every clickable
    /// metadata label. The click itself is handled in `mouseDown` in the main
    /// file — it routes to `.showMetadata`.
    func setDurationSizeHovered(_ hovered: Bool) {
        guard isDurationSizeHovered != hovered else { return }
        isDurationSizeHovered = hovered
        for label in metadataHoverLabels {
            applyDurationSizeUnderline(label, hovered: hovered)
        }
        if hovered {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// Re-applies the hover underline if the cursor is still over the hover
    /// area — `configure()` reassigns `stringValue` directly, which wipes any
    /// `attributedStringValue` attributes set for the underline style.
    func refreshDurationSizeHoverStyle() {
        guard isDurationSizeHovered else { return }
        for label in metadataHoverLabels {
            applyDurationSizeUnderline(label, hovered: true)
        }
    }

    private func applyDurationSizeUnderline(_ label: NSTextField, hovered: Bool) {
        let text = label.stringValue
        guard !text.isEmpty else { return }
        if hovered {
            // videoFormatLabel uses a pre-baked attributedStringValue to colour
            // the "Interlaced" suffix; preserve all of those attributes and
            // just overlay the underline style.
            let base = label.attributedStringValue.length == text.count
                ? NSMutableAttributedString(attributedString: label.attributedStringValue)
                : {
                    var attrs: [NSAttributedString.Key: Any] = [:]
                    if let font = label.font { attrs[.font] = font }
                    if let color = label.textColor { attrs[.foregroundColor] = color }
                    return NSMutableAttributedString(string: text, attributes: attrs)
                }()
            base.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: base.length)
            )
            // Break the underline at any inline " • " separators so labels that
            // bake multiple fields into one string (e.g. videoFormatLabel's
            // "1920×1080 • 25 fps") visually match the gap shown between
            // separate labels like duration and size.
            let nsText = text as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let found = nsText.range(of: " • ", options: [], range: searchRange)
                if found.location == NSNotFound { break }
                base.removeAttribute(.underlineStyle, range: found)
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: nsText.length - next)
            }
            label.attributedStringValue = base
        } else {
            // Reassign stringValue to drop any overlaid underline. Call sites
            // that rely on rich attributes (e.g. updateVideoFormatLabel) will
            // re-apply them in the next configure() pass.
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
