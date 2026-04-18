// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension VideoFileCellView {

    // MARK: - Comment Section Setup

    func setupCommentSection() {
        commentSection.orientation = .horizontal
        commentSection.spacing = 12
        commentSection.alignment = .centerY

        // Comment info button
        commentInfoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Preview comment")
        commentInfoButton.contentTintColor = .secondaryLabelColor
        commentInfoButton.isBordered = false
        commentInfoButton.target = self
        commentInfoButton.action = #selector(commentInfoClicked)
        commentInfoButton.setContentHuggingPriority(.required, for: .horizontal)

        // Comment text field
        commentField.font = .systemFont(ofSize: 12)
        commentField.placeholderString = "Add a comment (single line)..."
        commentField.isBezeled = true
        commentField.bezelStyle = .roundedBezel
        commentField.delegate = self
        commentField.lineBreakMode = .byTruncatingTail
        commentField.maximumNumberOfLines = 1
        commentField.usesSingleLineMode = true
        commentField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Comment toggle button
        commentToggleButton.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Toggle comment")
        commentToggleButton.isBordered = false
        commentToggleButton.target = self
        commentToggleButton.action = #selector(commentToggleClicked)
        commentToggleButton.setContentHuggingPriority(.required, for: .horizontal)

        // Date tag button
        dateTagButton.image = NSImage(systemSymbolName: "calendar.badge.checkmark", accessibilityDescription: "Date tag")
        dateTagButton.isBordered = false
        dateTagButton.target = self
        dateTagButton.action = #selector(dateTagClicked)
        dateTagButton.setContentHuggingPriority(.required, for: .horizontal)

        // Waveform button
        waveformButton.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Waveform video")
        waveformButton.isBordered = false
        waveformButton.target = self
        waveformButton.action = #selector(waveformClicked)
        waveformButton.setContentHuggingPriority(.required, for: .horizontal)
        waveformButton.isHidden = true

        // Waveform background image button
        waveformBgButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Background image")
        waveformBgButton.isBordered = false
        waveformBgButton.target = self
        waveformBgButton.action = #selector(waveformBgClicked)
        waveformBgButton.setContentHuggingPriority(.required, for: .horizontal)
        waveformBgButton.isHidden = true

        commentSection.addArrangedSubview(commentInfoButton)
        commentSection.addArrangedSubview(commentField)
        commentSection.addArrangedSubview(commentToggleButton)
        commentSection.addArrangedSubview(dateTagButton)
        commentSection.addArrangedSubview(waveformButton)
        commentSection.addArrangedSubview(waveformBgButton)

        contentStack.addArrangedSubview(commentSection)
        contentStack.setCustomSpacing(12, after: buttonsRow)

        commentSection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            commentSection.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            commentSection.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            commentField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Comment Section Update

    func updateCommentSection(config: VideoFileCellConfiguration) {
        let showComment = !config.isCompactMode && config.showCommentField
        let showWaveform = !config.isCompactMode && !config.hasVideoStream
        let showDateTag = !config.isCompactMode && config.showDateTagButton
        let showDCP = !config.isCompactMode && config.isDCPPreset

        // Always show in non-compact mode (comment toggle button is always visible)
        commentSection.isHidden = config.isCompactMode

        // Comment toggle button (always visible, uses cyan to distinguish from green transcription)
        commentToggleButton.isHidden = config.isCompactMode
        let commentActive = config.showCommentField
        commentToggleButton.image = commentActive ? VideoFileCellView.Symbol.textBubbleFill : VideoFileCellView.Symbol.textBubble
        commentToggleButton.contentTintColor = commentActive ? .systemCyan : .secondaryLabelColor

        // Comment field
        commentInfoButton.isHidden = !showComment || showDCP
        commentField.isHidden = !showComment || showDCP
        if showComment && !showDCP {
            commentField.stringValue = config.comment
            commentField.isEditable = config.status == .waiting
            commentField.alphaValue = config.status == .waiting ? 1.0 : 0.6

            // Focus management
            if config.isFocusedComment {
                window?.makeFirstResponder(commentField)
            }
        }

        // Date tag button
        dateTagButton.isHidden = !showDateTag || showDCP
        if showDateTag {
            let isActive = config.includeDateTag
            dateTagButton.image = isActive ? VideoFileCellView.Symbol.calendarCheck : VideoFileCellView.Symbol.calendarMinus
            dateTagButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }

        // Waveform controls
        waveformButton.isHidden = !showWaveform
        waveformBgButton.isHidden = !showWaveform
        if showWaveform {
            let isActive = config.waveformVideoEnabled
            waveformButton.image = isActive ? VideoFileCellView.Symbol.waveformCircleFill : VideoFileCellView.Symbol.waveformCircle
            waveformButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }
    }

    // MARK: - Comment Button Actions

    @objc private func commentInfoClicked() { actionHandler?(.showMetadata) }
    @objc private func dateTagClicked() { actionHandler?(.toggleDateTag) }
    @objc private func waveformClicked() { actionHandler?(.toggleWaveform) }
    @objc private func waveformBgClicked() { actionHandler?(.showBackgroundImagePicker) }
}
