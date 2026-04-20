// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ObjectiveC

extension VideoFileCellView {

    // MARK: - Comment popover storage (associated object — stored properties not allowed in extensions)

    private static var commentPopoverKey: UInt8 = 0
    private static var commentPopoverHostKey: UInt8 = 0
    private static var commentPreviewFullLabelKey: UInt8 = 0
    private static var commentPreviewComponentStackKey: UInt8 = 0

    var commentPopover: NSPopover? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverKey) as? NSPopover }
        set { objc_setAssociatedObject(self, &Self.commentPopoverKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var commentPopoverHost: NSViewController? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverHostKey) as? NSViewController }
        set { objc_setAssociatedObject(self, &Self.commentPopoverHostKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private var commentPreviewFullLabel: NSTextField? {
        get { objc_getAssociatedObject(self, &Self.commentPreviewFullLabelKey) as? NSTextField }
        set { objc_setAssociatedObject(self, &Self.commentPreviewFullLabelKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private var commentPreviewComponentStack: NSStackView? {
        get { objc_getAssociatedObject(self, &Self.commentPreviewComponentStackKey) as? NSStackView }
        set { objc_setAssociatedObject(self, &Self.commentPreviewComponentStackKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
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

        // Comment toggle — only shown when the output container can actually carry
        // a comment tag. Hides the button for DCP (which has its own metadata
        // sheet), image sequences, animated stills, and MXF-based presets.
        let commentsAvailable = !compact && config.preset.supportsMetadataComment
        commentToggleButton.isHidden = !commentsAvailable
        if commentsAvailable {
            let hasComment = !config.comment.isEmpty
            commentToggleButton.image = hasComment ? VideoFileCellView.Symbol.textBubbleFill : VideoFileCellView.Symbol.textBubble
            commentToggleButton.contentTintColor = hasComment ? .systemCyan : .secondaryLabelColor
            commentToggleButton.toolTip = hasComment
                ? "Edit comment — stored in the encoded file's metadata"
                : "Add a comment — stored in the encoded file's metadata"
        }

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
        if commentPopover?.isShown == true {
            if commentField.stringValue != config.comment {
                commentField.stringValue = config.comment
            }
            refreshPreviewContent(
                comment: config.comment,
                includeDateTag: config.includeDateTag
            )
        }

        // Focus handoff: if Tab navigated focus to this row, auto-open the
        // popover so the user can keep typing without reaching for the mouse.
        // Suppressed when the button itself is hidden (preset doesn't support
        // comments) — focus just moves past this row.
        if commentsAvailable,
           config.isFocusedComment,
           commentPopover?.isShown != true {
            presentCommentPopover()
        } else if !config.isFocusedComment, commentPopover?.isShown == true {
            // Focus moved elsewhere (e.g. Tab navigated to another row). Close
            // this row's popover so it doesn't linger behind the newly-opened one.
            commentPopover?.performClose(nil)
        }
    }

    // MARK: - Popover

    private func presentCommentPopover() {
        let popover: NSPopover
        if let existing = commentPopover, existing.contentViewController != nil {
            popover = existing
        } else {
            popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true

            let host = NSViewController()
            host.view = buildPopoverContentView()

            popover.contentViewController = host
            commentPopover = popover
            commentPopoverHost = host
        }

        // Re-read the current item's comment + date-tag state so the popover always
        // shows up-to-date values (global settings may have changed between opens).
        let currentComment = currentConfig?.comment ?? ""
        let includeDateTag = currentConfig?.includeDateTag ?? false
        commentField.stringValue = currentComment
        refreshPreviewContent(comment: currentComment, includeDateTag: includeDateTag)

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

    // MARK: - Popover Content Builder

    /// Builds the popover layout once. The editable field is reused, while the
    /// breakdown and full-output preview are rebuilt on each open (cheap — a few
    /// labels) so they reflect live UserDefaults changes to prefix/suffix/etc.
    private func buildPopoverContentView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Metadata Comment")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Embedded in the exported file's metadata so media players can surface it.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.maximumNumberOfLines = 2

        let topDivider = makePopoverDivider()

        // Editable comment field (reused across opens to keep delegate wiring intact).
        commentField.translatesAutoresizingMaskIntoConstraints = false

        // Component breakdown — rebuilt per-open.
        let componentStack = NSStackView()
        componentStack.orientation = .vertical
        componentStack.alignment = .leading
        componentStack.spacing = 3
        componentStack.translatesAutoresizingMaskIntoConstraints = false
        commentPreviewComponentStack = componentStack

        let middleDivider = makePopoverDivider()

        let fullOutputCaption = NSTextField(labelWithString: "Full output:")
        fullOutputCaption.font = .systemFont(ofSize: 11)
        fullOutputCaption.textColor = .secondaryLabelColor
        fullOutputCaption.translatesAutoresizingMaskIntoConstraints = false

        let fullLabel = NSTextField(wrappingLabelWithString: "")
        fullLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fullLabel.textColor = .labelColor
        fullLabel.isSelectable = true
        fullLabel.translatesAutoresizingMaskIntoConstraints = false
        fullLabel.maximumNumberOfLines = 0
        fullLabel.preferredMaxLayoutWidth = 376 // content width: 400 - 2*12 padding
        commentPreviewFullLabel = fullLabel

        let fullLabelBackground = NSView()
        fullLabelBackground.wantsLayer = true
        fullLabelBackground.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        fullLabelBackground.layer?.cornerRadius = 6
        fullLabelBackground.layer?.borderColor = NSColor.separatorColor.cgColor
        fullLabelBackground.layer?.borderWidth = 1
        fullLabelBackground.translatesAutoresizingMaskIntoConstraints = false
        fullLabelBackground.addSubview(fullLabel)

        let bottomDivider = makePopoverDivider()

        let footerIcon = NSImageView()
        footerIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        footerIcon.contentTintColor = .secondaryLabelColor
        footerIcon.translatesAutoresizingMaskIntoConstraints = false

        let footerLabel = NSTextField(wrappingLabelWithString: "Change prefix, suffix, separator, and date format in Settings › Metadata.")
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.maximumNumberOfLines = 2

        let footerStack = NSStackView(views: [footerIcon, footerLabel])
        footerStack.orientation = .horizontal
        footerStack.alignment = .top
        footerStack.spacing = 6
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)
        container.addSubview(topDivider)
        container.addSubview(commentField)
        container.addSubview(componentStack)
        container.addSubview(middleDivider)
        container.addSubview(fullOutputCaption)
        container.addSubview(fullLabelBackground)
        container.addSubview(bottomDivider)
        container.addSubview(footerStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 400),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            topDivider.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            topDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            topDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            commentField.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 10),
            commentField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            commentField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            commentField.heightAnchor.constraint(equalToConstant: 24),

            componentStack.topAnchor.constraint(equalTo: commentField.bottomAnchor, constant: 10),
            componentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            componentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            middleDivider.topAnchor.constraint(equalTo: componentStack.bottomAnchor, constant: 10),
            middleDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            middleDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            fullOutputCaption.topAnchor.constraint(equalTo: middleDivider.bottomAnchor, constant: 10),
            fullOutputCaption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            fullLabelBackground.topAnchor.constraint(equalTo: fullOutputCaption.bottomAnchor, constant: 4),
            fullLabelBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            fullLabelBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            fullLabel.topAnchor.constraint(equalTo: fullLabelBackground.topAnchor, constant: 8),
            fullLabel.leadingAnchor.constraint(equalTo: fullLabelBackground.leadingAnchor, constant: 8),
            fullLabel.trailingAnchor.constraint(equalTo: fullLabelBackground.trailingAnchor, constant: -8),
            fullLabel.bottomAnchor.constraint(equalTo: fullLabelBackground.bottomAnchor, constant: -8),

            bottomDivider.topAnchor.constraint(equalTo: fullLabelBackground.bottomAnchor, constant: 10),
            bottomDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bottomDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            footerStack.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: 10),
            footerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            footerIcon.widthAnchor.constraint(equalToConstant: 14),
            footerIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        return container
    }

    private func makePopoverDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    // MARK: - Preview Content

    /// Recomputes the breakdown rows and the full-output preview from the
    /// current comment text + UserDefaults. Called on popover open and on every
    /// text-change notification so the preview updates live while typing.
    func refreshPreviewContent(comment: String, includeDateTag: Bool) {
        guard let componentStack = commentPreviewComponentStack,
              let fullLabel = commentPreviewFullLabel else { return }

        let prefix = UserDefaults.standard.string(forKey: AppConstants.commentPrefixKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix = UserDefaults.standard.string(forKey: AppConstants.commentSuffixKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let separator = UserDefaults.standard.string(forKey: AppConstants.commentSeparatorKey)
            ?? AppConstants.defaultCommentSeparator
        let dateFormat = UserDefaults.standard.string(forKey: AppConstants.commentDateFormatKey)
            ?? AppConstants.defaultCommentDateFormat
        let rawTagPrefix = UserDefaults.standard.string(forKey: AppConstants.dateTagPrefixKey)
            ?? AppConstants.defaultDateTagPrefix
        let tagPrefix = rawTagPrefix.isEmpty ? AppConstants.defaultDateTagPrefix : rawTagPrefix

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = dateFormat
        let dateString = dateFormatter.string(from: Date())
        let dateTagValue = "\(tagPrefix): \(dateString)"

        // Rebuild component rows.
        componentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if includeDateTag {
            componentStack.addArrangedSubview(makeComponentRow(label: "Date tag:", value: dateTagValue, muted: false))
        }
        if !prefix.isEmpty {
            componentStack.addArrangedSubview(makeComponentRow(label: "Prefix:", value: prefix, muted: false))
        }
        componentStack.addArrangedSubview(makeComponentRow(
            label: "Comment:",
            value: trimmedComment.isEmpty ? "(empty)" : trimmedComment,
            muted: trimmedComment.isEmpty
        ))
        if !suffix.isEmpty {
            componentStack.addArrangedSubview(makeComponentRow(label: "Suffix:", value: suffix, muted: false))
        }

        // Rebuild full output.
        var parts: [String] = []
        if includeDateTag { parts.append(dateTagValue) }
        if !prefix.isEmpty { parts.append(prefix) }
        if !trimmedComment.isEmpty { parts.append(trimmedComment) }
        if !suffix.isEmpty { parts.append(suffix) }

        if parts.isEmpty {
            fullLabel.stringValue = "(no comment will be added)"
            fullLabel.textColor = .secondaryLabelColor
        } else {
            fullLabel.stringValue = parts.joined(separator: separator)
            fullLabel.textColor = .labelColor
        }
    }

    private func makeComponentRow(label: String, value: String, muted: Bool) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = .systemFont(ofSize: 11)
        valueField.textColor = muted ? .secondaryLabelColor : .labelColor
        valueField.isSelectable = true
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.maximumNumberOfLines = 0

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            labelField.widthAnchor.constraint(equalToConstant: 70),
        ])

        return row
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
