// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ObjectiveC

extension VideoFileCellView {

    // MARK: - Comment popover storage (associated object — stored properties not allowed in extensions)

    private static var commentPopoverKey: UInt8 = 0
    private static var commentPopoverHostKey: UInt8 = 0

    var commentPopover: NSPopover? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverKey) as? NSPopover }
        set { objc_setAssociatedObject(self, &Self.commentPopoverKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var commentPopoverHost: NSViewController? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverHostKey) as? NSViewController }
        set { objc_setAssociatedObject(self, &Self.commentPopoverHostKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    // MARK: - Comment Button + Popover Setup

    /// Configures the comment / date-tag / waveform buttons as toggle-style icons so
    /// they render the same way as the encode / transcription / upload buttons and can
    /// sit alongside them in the buttons row. The comment field itself no longer lives
    /// inline — it opens in a popover anchored to the comment button.
    func setupCommentSection() {
        setupToggleButton(commentToggleButton, symbol: "text.bubble", action: #selector(commentToggleClicked))
        setupToggleButton(dateTagButton, symbol: "calendar.badge.checkmark", action: #selector(dateTagClicked))
        setupToggleButton(waveformButton, symbol: "waveform.circle", action: #selector(waveformClicked))
        setupToggleButton(waveformBgButton, symbol: "photo", action: #selector(waveformBgClicked))

        // The info and comment-section containers from the old layout aren't used anymore
        // but are kept as plain references so the existing update paths don't crash.
        commentInfoButton.isHidden = true
        commentSection.isHidden = true

        // Configure the comment field for use inside the popover.
        commentField.font = .systemFont(ofSize: 12)
        commentField.placeholderString = "Add a comment (single line)…"
        commentField.isBezeled = true
        commentField.bezelStyle = .roundedBezel
        commentField.delegate = self
        commentField.lineBreakMode = .byTruncatingTail
        commentField.maximumNumberOfLines = 1
        commentField.usesSingleLineMode = true
        commentField.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Comment Section Update

    func updateCommentSection(config: VideoFileCellConfiguration) {
        // Compact mode hides all of these controls; in normal mode each button has its
        // own visibility rule based on what the item actually supports.
        let compact = config.isCompactMode

        // Comment toggle — always shown in non-compact mode. Icon reflects whether the
        // item has any comment text so the user can tell at a glance without opening
        // the popover.
        commentToggleButton.isHidden = compact
        let hasComment = !config.comment.isEmpty
        commentToggleButton.image = hasComment ? VideoFileCellView.Symbol.textBubbleFill : VideoFileCellView.Symbol.textBubble
        commentToggleButton.contentTintColor = hasComment ? .systemCyan : .secondaryLabelColor
        commentToggleButton.toolTip = hasComment
            ? "Edit comment — stored in the encoded file's metadata"
            : "Add a comment — stored in the encoded file's metadata"

        // Date tag button — respects the "show date tag" preference.
        let showDateTag = !compact && config.showDateTagButton
        dateTagButton.isHidden = !showDateTag
        if showDateTag {
            let isActive = config.includeDateTag
            dateTagButton.image = isActive ? VideoFileCellView.Symbol.calendarCheck : VideoFileCellView.Symbol.calendarMinus
            dateTagButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }

        // Waveform controls only apply to audio-only items.
        let showWaveform = !compact && !config.hasVideoStream
        waveformButton.isHidden = !showWaveform
        waveformBgButton.isHidden = !showWaveform
        if showWaveform {
            let isActive = config.waveformVideoEnabled
            waveformButton.image = isActive ? VideoFileCellView.Symbol.waveformCircleFill : VideoFileCellView.Symbol.waveformCircle
            waveformButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }

        // Keep the popover's field in sync if it happens to be open.
        if commentPopover?.isShown == true, commentField.stringValue != config.comment {
            commentField.stringValue = config.comment
        }
    }

    // MARK: - Popover

    private func presentCommentPopover() {
        let popover: NSPopover
        if let existing = commentPopover {
            popover = existing
        } else {
            popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true

            let host = NSViewController()
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(commentField)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 320),
                commentField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                commentField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                commentField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                commentField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
                commentField.heightAnchor.constraint(equalToConstant: 28),
            ])
            host.view = container

            popover.contentViewController = host
            commentPopover = popover
            commentPopoverHost = host
        }

        if let currentComment = currentConfig?.comment {
            commentField.stringValue = currentComment
        }

        popover.show(
            relativeTo: commentToggleButton.bounds,
            of: commentToggleButton,
            preferredEdge: .maxY
        )

        // Focus the field so the user can type immediately.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.commentField.window?.makeFirstResponder(self.commentField)
        }
    }

    // MARK: - Comment Button Actions

    @objc private func dateTagClicked() { actionHandler?(.toggleDateTag) }
    @objc private func waveformClicked() { actionHandler?(.toggleWaveform) }
    @objc private func waveformBgClicked() { actionHandler?(.showBackgroundImagePicker) }

    /// Opens a popover anchored to the comment button so the user can edit the
    /// comment text without the field occupying space in the row.
    @objc func commentPopoverRequested() {
        presentCommentPopover()
    }
}
