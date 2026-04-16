// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import OSLog

/// Pure AppKit cell view for a video file queue row.
/// Replaces the SwiftUI VideoFileRowView for smooth scrolling performance.
/// All subviews are created once in init; `configure()` updates values only.
final class VideoFileCellView: NSTableCellView, NSTextFieldDelegate {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoFileCellView")

    // MARK: - State

    private(set) var currentItemID: UUID?
    var actionHandler: ((CellAction) -> Void)?
    private var currentConfig: VideoFileCellConfiguration?

    // MARK: - Card Container

    private let cardView = NSView()
    private let groupAccentLayer = CALayer()

    // MARK: - Main Layout

    private let mainHStack = NSStackView()

    // Thumbnail area (left)
    let thumbnailContainer = NSView()
    let thumbnailImageView = NSImageView()
    private let checkerboardLayer = CALayer()
    private let thumbnailBorderLayer = CAShapeLayer()

    var trackingArea: NSTrackingArea?

    // Content area (right)
    let contentStack = NSStackView()

    // Row 1: Filenames
    private let filenameStack = NSStackView()
    private let inputNameLabel = NSTextField(labelWithString: "")
    private let arrowLabel = NSTextField(labelWithString: "→")
    private let outputNameLabel = NSTextField(labelWithString: "")
    private let outputNameField = NSTextField() // editable, hidden by default
    private let mergeIndicator = NSImageView()
    private let finderButton = NSButton()
    private let downloadedFinderButton = NSButton()
    private let dragButton = DraggableFileImageView()
    private let liveRecordingBadge = NSView()
    private let liveRecordingLabel = NSTextField(labelWithString: "LIVE")

    // Row 2: Progress bar
    private let progressBar = NSProgressIndicator()

    // Row 3: Info + buttons (compact uses this for all controls)
    let infoStack = NSStackView()
    let durationLabel = NSTextField(labelWithString: "")
    let durationWarningIcon = NSImageView()
    let dotSeparator = NSTextField(labelWithString: "•")
    let sizeLabel = NSTextField(labelWithString: "")

    // Toggle buttons (normal mode — ordered by processing pipeline)
    let encodeButton = NSButton()
    let autoEncodeButton = NSButton()
    let uploadButton = NSButton()
    let transcriptionButton = NSButton()
    let ocrButton = NSButton()
    let analyticsButton = NSButton()
    let commentToggleButton = NSButton()

    // Action buttons container
    let actionButtonStack = NSStackView()
    let deleteButton = NSButton()
    let resetButton = NSButton()
    let cancelButton = NSButton()
    let stopDownloadButton = NSButton()
    let cancelDownloadButton = NSButton()
    let cancelScheduledButton = NSButton()
    let retryDownloadButton = NSButton()
    let redownloadButton = NSButton()
    let cancelSubtitleButton = NSButton()
    let cancelAnalyticsButton = NSButton()

    // Row 4: Buttons row (action + toggle buttons)
    let buttonsRow = NSStackView()
    let buttonDivider = NSView()
    private let rightSideStack = NSStackView()
    private let statusRow = NSStackView()

    // Status labels (displayed in info row)
    let overwriteWarningLabel = NSTextField(labelWithString: "")
    let outputSizeLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")

    // Status capsule (colored pill label, e.g. "WAITING", "ENCODING", "DONE", "FAILED")
    let statusCapsule = NSView()
    let capsuleIcon = NSImageView()
    let capsuleLabel = NSTextField(labelWithString: "")

    // Row 5: Comment section (hidden in compact mode)
    let commentSection = NSStackView()
    let commentInfoButton = NSButton()
    let commentField = NSTextField()
    let dateTagButton = NSButton()
    let waveformButton = NSButton()
    let waveformBgButton = NSButton()

    // Compact mode controls
    private let compactControlStack = NSStackView()

    // Badges on thumbnail
    let audioRoutingBadge = BadgeView()
    let timecodeBadge = BadgeView()
    let trimBadge = BadgeView()
    let cropBadge = BadgeView()
    let uploadBadge = BadgeView()
    let analyticsBadgeView = BadgeView()

    // Overlay action buttons (shown on thumbnail hover)
    let overlayPlayButton = BadgeView()
    let overlayTrimButton = BadgeView()
    let overlayMetadataButton = BadgeView()

    // Selection border
    private let selectionBorderLayer = CAShapeLayer()

    // MARK: - Sizing Constants

    private var thumbnailWidth: CGFloat { isCompact ? 160 : 240 }
    private var thumbnailHeight: CGFloat { isCompact ? 75 : 150 }
    private var isCompact = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        // Card view with rounded corners and shadow
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        // Dark card background (updateLayer handles group-child tint)
        cardView.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1.0).cgColor

        // Left accent bar for encoding group child rows
        groupAccentLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        groupAccentLayer.cornerRadius = 1
        groupAccentLayer.isHidden = true
        cardView.layer?.addSublayer(groupAccentLayer)

        // Shadow on self (outside the clip)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        // Pink/red border — high zPosition so it draws above all subviews
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.lineWidth = 1.2
        selectionBorderLayer.strokeColor = NSColor(red: 0.85, green: 0.25, blue: 0.35, alpha: 0.6).cgColor
        selectionBorderLayer.zPosition = 100
        cardView.layer?.addSublayer(selectionBorderLayer)

        // Main horizontal stack: thumbnail | content
        mainHStack.orientation = .horizontal
        mainHStack.spacing = 0
        mainHStack.alignment = .top
        mainHStack.distribution = .fill
        mainHStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(mainHStack)

        setupThumbnailArea()
        setupContentArea()

        // Constraints
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            mainHStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            mainHStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            mainHStack.topAnchor.constraint(equalTo: cardView.topAnchor),
            mainHStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor),
        ])
    }

    private func setupThumbnailArea() {
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.masksToBounds = true
        // Only round the right corners — left side is flush with card edge
        thumbnailContainer.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        thumbnailContainer.layer?.cornerRadius = 8

        // Checkerboard background — spans full row height, pinned to left edge of card
        let checkSize: CGFloat = 16
        let checkImage = NSImage(size: NSSize(width: checkSize * 2, height: checkSize * 2), flipped: true) { rect in
            NSColor(white: 0.2, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.3, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: checkSize, height: checkSize).fill()
            NSRect(x: checkSize, y: checkSize, width: checkSize, height: checkSize).fill()
            return true
        }
        let checkerView = NSView()
        checkerView.wantsLayer = true
        if let cgImage = checkImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            checkerView.layer?.backgroundColor = NSColor(patternImage: NSImage(cgImage: cgImage, size: NSSize(width: checkSize * 2, height: checkSize * 2))).cgColor
        }
        checkerView.layer?.masksToBounds = true
        checkerView.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        checkerView.layer?.cornerRadius = 8
        checkerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(checkerView, positioned: .below, relativeTo: mainHStack)
        NSLayoutConstraint.activate([
            checkerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            checkerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            checkerView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            checkerView.widthAnchor.constraint(equalToConstant: 240),
        ])

        // Thumbnail image
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(thumbnailImageView)

        // Border
        thumbnailBorderLayer.fillColor = nil
        thumbnailBorderLayer.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailBorderLayer.lineWidth = 1
        thumbnailContainer.layer?.addSublayer(thumbnailBorderLayer)

        setupBadges()
        setupOverlayButtons()

        mainHStack.addArrangedSubview(thumbnailContainer)

        // Thumbnail: fixed width, full height of parent
        let widthConstraint = thumbnailContainer.widthAnchor.constraint(equalToConstant: 200)
        widthConstraint.identifier = "thumbnailWidth"
        NSLayoutConstraint.activate([
            widthConstraint,
            thumbnailContainer.topAnchor.constraint(equalTo: mainHStack.topAnchor),
            thumbnailContainer.bottomAnchor.constraint(equalTo: mainHStack.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),
        ])
    }

    private func setupContentArea() {
        contentStack.orientation = .vertical
        contentStack.spacing = 4
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        setupFilenameRow()
        setupProgressBar()
        setupInfoRow()
        setupButtonsRow()
        setupCommentSection()

        // Wrap content stack in a padded container
        let contentPadding = NSView()
        contentPadding.translatesAutoresizingMaskIntoConstraints = false
        contentPadding.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentPadding.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: contentPadding.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentPadding.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentPadding.bottomAnchor, constant: -8),
        ])

        mainHStack.addArrangedSubview(contentPadding)

        // Content should fill remaining width
        contentPadding.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func setupFilenameRow() {
        filenameStack.orientation = .horizontal
        filenameStack.spacing = 4
        filenameStack.alignment = .firstBaseline

        configureLabel(inputNameLabel, font: .systemFont(ofSize: 13, weight: .semibold))
        inputNameLabel.lineBreakMode = .byTruncatingMiddle
        inputNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureLabel(arrowLabel, font: .systemFont(ofSize: 13, weight: .regular))
        arrowLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureLabel(outputNameLabel, font: .systemFont(ofSize: 13, weight: .semibold))
        outputNameLabel.lineBreakMode = .byTruncatingMiddle
        outputNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outputNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Editable output name field (hidden by default)
        outputNameField.font = .systemFont(ofSize: 13, weight: .semibold)
        outputNameField.isHidden = true
        outputNameField.delegate = self
        outputNameField.translatesAutoresizingMaskIntoConstraints = false

        // Merge indicator
        mergeIndicator.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Merge")
        mergeIndicator.contentTintColor = .secondaryLabelColor
        mergeIndicator.translatesAutoresizingMaskIntoConstraints = false
        mergeIndicator.isHidden = true
        // Rotate 90 degrees
        mergeIndicator.frameCenterRotation = 90

        // Finder button (shows encoded output file)
        finderButton.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Show in Finder")
        finderButton.isBordered = false
        finderButton.bezelStyle = .inline
        finderButton.target = self
        finderButton.action = #selector(finderButtonClicked)
        finderButton.isHidden = true
        finderButton.setContentHuggingPriority(.required, for: .horizontal)

        // Downloaded source file Finder button (shows original downloaded file)
        downloadedFinderButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Show downloaded file in Finder")
        downloadedFinderButton.isBordered = false
        downloadedFinderButton.bezelStyle = .inline
        downloadedFinderButton.target = self
        downloadedFinderButton.action = #selector(downloadedFinderButtonClicked)
        downloadedFinderButton.isHidden = true
        downloadedFinderButton.contentTintColor = .secondaryLabelColor
        downloadedFinderButton.toolTip = "Show downloaded source file in Finder"
        downloadedFinderButton.setContentHuggingPriority(.required, for: .horizontal)

        // Drag-to-share button
        dragButton.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Drag to share file")
        dragButton.translatesAutoresizingMaskIntoConstraints = false
        dragButton.isHidden = true
        dragButton.setContentHuggingPriority(.required, for: .horizontal)

        // Live recording badge
        liveRecordingBadge.wantsLayer = true
        liveRecordingBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        liveRecordingBadge.layer?.cornerRadius = 4
        liveRecordingBadge.isHidden = true
        liveRecordingBadge.translatesAutoresizingMaskIntoConstraints = false
        configureLabel(liveRecordingLabel, font: .systemFont(ofSize: 9, weight: .bold), color: .white)
        liveRecordingBadge.addSubview(liveRecordingLabel)
        liveRecordingLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            liveRecordingLabel.leadingAnchor.constraint(equalTo: liveRecordingBadge.leadingAnchor, constant: 4),
            liveRecordingLabel.trailingAnchor.constraint(equalTo: liveRecordingBadge.trailingAnchor, constant: -4),
            liveRecordingLabel.centerYAnchor.constraint(equalTo: liveRecordingBadge.centerYAnchor),
        ])

        filenameStack.addArrangedSubview(inputNameLabel)
        filenameStack.addArrangedSubview(downloadedFinderButton)
        filenameStack.addArrangedSubview(arrowLabel)
        filenameStack.addArrangedSubview(outputNameLabel)
        filenameStack.addArrangedSubview(outputNameField)
        filenameStack.addArrangedSubview(mergeIndicator)
        filenameStack.addArrangedSubview(finderButton)
        filenameStack.addArrangedSubview(dragButton)
        filenameStack.addArrangedSubview(liveRecordingBadge)

        contentStack.addArrangedSubview(filenameStack)

        // Filename stack fills width
        filenameStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filenameStack.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            filenameStack.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            // Equal-width constraint ensures both filename labels share available space
            // evenly, preventing one long name from pushing the other off-screen
            inputNameLabel.widthAnchor.constraint(equalTo: outputNameLabel.widthAnchor),
        ])
    }

    private func setupProgressBar() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
    }

    private func setupInfoRow() {
        infoStack.orientation = .horizontal
        infoStack.spacing = 6
        infoStack.alignment = .centerY

        configureLabel(durationLabel, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        durationWarningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        durationWarningIcon.contentTintColor = .systemYellow
        durationWarningIcon.isHidden = true
        durationWarningIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            durationWarningIcon.widthAnchor.constraint(equalToConstant: 14),
            durationWarningIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        configureLabel(dotSeparator, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        configureLabel(sizeLabel, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

        // Overwrite warning (inline)
        configureLabel(overwriteWarningLabel, font: .systemFont(ofSize: 11), color: .systemOrange)
        overwriteWarningLabel.stringValue = "Existing file will be overwritten"
        overwriteWarningLabel.isHidden = true

        // Output size (inline)
        configureLabel(outputSizeLabel, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        outputSizeLabel.isHidden = true

        infoStack.addArrangedSubview(durationLabel)
        infoStack.addArrangedSubview(durationWarningIcon)
        infoStack.addArrangedSubview(dotSeparator)
        infoStack.addArrangedSubview(sizeLabel)
        infoStack.addArrangedSubview(overwriteWarningLabel)
        infoStack.addArrangedSubview(outputSizeLabel)

        contentStack.addArrangedSubview(infoStack)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoStack.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
    }

    private func setupButtonsRow() {
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 6
        buttonsRow.alignment = .top

        // Toggle buttons (left side — ordered by processing pipeline)
        setupToggleButton(encodeButton, symbol: "play.fill", action: #selector(encodeButtonClicked))
        setupToggleButton(autoEncodeButton, symbol: "play", action: #selector(autoEncodeButtonClicked))
        autoEncodeButton.isHidden = true
        setupToggleButton(transcriptionButton, symbol: "captions.bubble", action: #selector(transcriptionButtonClicked))
        setupToggleButton(ocrButton, symbol: "text.viewfinder", action: #selector(ocrButtonClicked))
        ocrButton.isHidden = true
        setupToggleButton(analyticsButton, symbol: "chart.bar.xaxis", action: #selector(analyticsButtonClicked))
        setupToggleButton(uploadButton, symbol: "icloud.and.arrow.up", action: #selector(uploadButtonClicked))

        // Divider between toggle buttons and right side
        buttonDivider.wantsLayer = true
        buttonDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        buttonDivider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonDivider.widthAnchor.constraint(equalToConstant: 1),
            buttonDivider.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Right side: capsule + status on top, action buttons below
        rightSideStack.orientation = .vertical
        rightSideStack.spacing = 4
        rightSideStack.alignment = .trailing

        // Top row: capsule + status label
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        setupStatusCapsule()
        configureLabel(statusLabel, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusRow.addArrangedSubview(statusCapsule)
        statusRow.addArrangedSubview(statusLabel)

        // Bottom row: action buttons
        setupActionButtons()

        rightSideStack.addArrangedSubview(statusRow)
        rightSideStack.addArrangedSubview(actionButtonStack)

        // Layout: [toggles in pipeline order] ... [divider] [rightSideStack]
        // Gravity areas pin the right side to the trailing edge, ensuring
        // action buttons don't shift when status capsule width changes.
        buttonsRow.setViews([encodeButton, autoEncodeButton, transcriptionButton, ocrButton, analyticsButton, uploadButton], in: .leading)
        buttonsRow.setViews([buttonDivider, rightSideStack], in: .trailing)

        contentStack.addArrangedSubview(buttonsRow)
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonsRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            buttonsRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
    }

    private func setupActionButtons() {
        actionButtonStack.orientation = .horizontal
        actionButtonStack.spacing = 2

        setupActionButton(deleteButton, symbol: "xmark.circle.fill", color: .systemRed, action: #selector(deleteButtonClicked))
        setupActionButton(resetButton, symbol: "arrow.counterclockwise.circle", color: .systemBlue, action: #selector(resetButtonClicked))
        setupActionButton(cancelButton, symbol: "xmark.circle", color: .systemRed, action: #selector(cancelButtonClicked))
        setupActionButton(stopDownloadButton, symbol: "stop.circle.fill", color: .systemOrange, action: #selector(stopDownloadClicked))
        setupActionButton(cancelDownloadButton, symbol: "xmark.circle.fill", color: .systemRed, action: #selector(cancelDownloadClicked))
        setupActionButton(cancelScheduledButton, symbol: "clock.badge.xmark", color: .systemCyan, action: #selector(cancelScheduledClicked))
        setupActionButton(retryDownloadButton, symbol: "arrow.clockwise.circle", color: .systemOrange, action: #selector(retryDownloadClicked))
        setupActionButton(redownloadButton, symbol: "arrow.down.circle.fill", color: .systemOrange, action: #selector(redownloadClicked))
        setupActionButton(cancelSubtitleButton, symbol: "xmark.circle", color: .systemOrange, action: #selector(cancelSubtitleClicked))
        setupActionButton(cancelAnalyticsButton, symbol: "xmark.circle", color: .systemOrange, action: #selector(cancelAnalyticsClicked))

        actionButtonStack.addArrangedSubview(stopDownloadButton)
        actionButtonStack.addArrangedSubview(cancelDownloadButton)
        actionButtonStack.addArrangedSubview(cancelScheduledButton)
        actionButtonStack.addArrangedSubview(retryDownloadButton)
        actionButtonStack.addArrangedSubview(redownloadButton)
        actionButtonStack.addArrangedSubview(cancelButton)
        actionButtonStack.addArrangedSubview(cancelSubtitleButton)
        actionButtonStack.addArrangedSubview(cancelAnalyticsButton)
        actionButtonStack.addArrangedSubview(deleteButton)
        actionButtonStack.addArrangedSubview(resetButton)
    }

    private func setupStatusCapsule() {
        statusCapsule.wantsLayer = true
        statusCapsule.layer?.cornerRadius = 10
        statusCapsule.layer?.borderWidth = 1.2
        statusCapsule.translatesAutoresizingMaskIntoConstraints = false

        capsuleIcon.translatesAutoresizingMaskIntoConstraints = false
        capsuleIcon.contentTintColor = .secondaryLabelColor
        statusCapsule.addSubview(capsuleIcon)

        capsuleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        capsuleLabel.textColor = .secondaryLabelColor
        capsuleLabel.isBezeled = false
        capsuleLabel.isEditable = false
        capsuleLabel.isSelectable = false
        capsuleLabel.drawsBackground = false
        capsuleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCapsule.addSubview(capsuleLabel)

        NSLayoutConstraint.activate([
            capsuleIcon.leadingAnchor.constraint(equalTo: statusCapsule.leadingAnchor, constant: 7),
            capsuleIcon.centerYAnchor.constraint(equalTo: statusCapsule.centerYAnchor),
            capsuleIcon.widthAnchor.constraint(equalToConstant: 10),
            capsuleIcon.heightAnchor.constraint(equalToConstant: 10),

            capsuleLabel.leadingAnchor.constraint(equalTo: capsuleIcon.trailingAnchor, constant: 3),
            capsuleLabel.trailingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: -8),
            capsuleLabel.centerYAnchor.constraint(equalTo: statusCapsule.centerYAnchor),

            statusCapsule.heightAnchor.constraint(equalToConstant: 20),
        ])

        statusCapsule.setContentHuggingPriority(.required, for: .horizontal)
        statusCapsule.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - Helpers

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor = .labelColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupToggleButton(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 14
        button.layer?.borderWidth = 1.5
        button.layer?.borderColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupActionButton(_ button: NSButton, symbol: String, color: NSColor, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = color
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Configure

    func configure(with config: VideoFileCellConfiguration, actionHandler: @escaping (CellAction) -> Void) {
        let prev = self.currentConfig
        self.actionHandler = actionHandler

        // Skip entirely if config unchanged
        if let prev, prev == config {
            return
        }

        let isFirstConfigure = prev == nil || prev?.itemID != config.itemID
        self.currentItemID = config.itemID

        // Compact mode change — update thumbnail size
        if isFirstConfigure || prev?.isCompactMode != config.isCompactMode {
            self.isCompact = config.isCompactMode
            updateThumbnailSize()
            durationLabel.isHidden = config.isCompactMode
            dotSeparator.isHidden = config.isCompactMode
            sizeLabel.isHidden = config.isCompactMode
        }

        // Group child background — trigger layer update when membership changes
        if isFirstConfigure || prev?.isGroupChild != config.isGroupChild {
            groupAccentLayer.isHidden = !config.isGroupChild
            needsDisplay = true
        }

        // Thumbnail
        if isFirstConfigure || prev?.thumbnailImage !== config.thumbnailImage {
            thumbnailImageView.image = config.thumbnailImage
        }

        // Filenames
        if isFirstConfigure || prev?.name != config.name || prev?.sourceURL != config.sourceURL {
            inputNameLabel.stringValue = config.name
            // Show full path in tooltip; append source URL for downloads
            var tip = config.url.path
            if let source = config.sourceURL {
                tip += "\n\nSource: \(source)"
            }
            inputNameLabel.toolTip = tip
        }
        if isFirstConfigure || prev?.outputURL != config.outputURL || prev?.outputFileNameOverride != config.outputFileNameOverride || prev?.status != config.status || prev?.outputFileExists != config.outputFileExists {
            let outputName = displayOutputFilename(config: config)
            outputNameLabel.stringValue = outputName
            outputNameLabel.toolTip = outputName
            outputNameLabel.textColor = (config.status == .waiting && config.outputFileExists) ? .systemOrange : .labelColor
        }

        // Downloaded source file Finder button (for yt-dlp items)
        if isFirstConfigure || prev?.sourceURL != config.sourceURL || prev?.isDownloading != config.isDownloading || prev?.status != config.status {
            let showDownloadedButton = config.sourceURL != nil && !config.isDownloading && config.downloadError == nil
            downloadedFinderButton.isHidden = !showDownloadedButton
        }

        // Merge
        if isFirstConfigure || prev?.mergeClipsAvailable != config.mergeClipsAvailable || prev?.mergeClipsEnabled != config.mergeClipsEnabled {
            mergeIndicator.isHidden = !config.mergeClipsAvailable
            mergeIndicator.contentTintColor = config.mergeClipsEnabled ? .systemGreen : NSColor.gray.withAlphaComponent(0.55)
        }

        // Finder button
        if isFirstConfigure || prev?.status != config.status || prev?.outputFileExists != config.outputFileExists {
            let showFinderButton = config.status == .done || (config.status == .waiting && config.outputFileExists)
            finderButton.isHidden = !showFinderButton
            finderButton.contentTintColor = config.status == .done ? .systemBlue : .systemOrange

            // Drag-to-share icon (shown alongside Finder button)
            dragButton.isHidden = !showFinderButton
            let dragColor: NSColor = config.status == .done ? .systemBlue : .systemOrange
            dragButton.contentTintColor = dragColor
            dragButton.fileURL = config.outputURL
            dragButton.toolTip = config.status == .done
                ? "Drag this icon to share the exported file with other apps."
                : "Output file already exists and will be overwritten during conversion. Drag to share or archive before converting."
        }

        // Live recording
        if isFirstConfigure || prev?.isLiveStreamRecording != config.isLiveStreamRecording {
            liveRecordingBadge.isHidden = !config.isLiveStreamRecording
        }

        // Progress bar
        if isFirstConfigure || prev?.status != config.status || prev?.progress != config.progress || prev?.isDownloading != config.isDownloading || prev?.uploadStatus != config.uploadStatus || prev?.subtitleStatus != config.subtitleStatus || prev?.analyticsStatus != config.analyticsStatus {
            updateProgressBar(config: config)
        }

        // Duration/size
        if isFirstConfigure || prev?.duration != config.duration {
            durationLabel.stringValue = config.duration
        }
        if isFirstConfigure || prev?.formattedSize != config.formattedSize {
            sizeLabel.stringValue = config.formattedSize
        }

        // Toggle buttons — only when relevant state changes
        updateToggleButtons(config: config)

        // Action buttons — only when status changes
        if isFirstConfigure || prev?.status != config.status || prev?.isDownloading != config.isDownloading || prev?.scheduledDownloadTime != config.scheduledDownloadTime || prev?.downloadError != config.downloadError || prev?.fileAlreadyExistsPath != config.fileAlreadyExistsPath || prev?.subtitleStatus != config.subtitleStatus || prev?.analyticsStatus != config.analyticsStatus {
            updateActionButtons(config: config)
        }

        // Status text + capsule
        updateStatusRow(config: config)
        updateStatusCapsule(config: config)

        // Comment section — only on relevant changes
        if isFirstConfigure || prev?.comment != config.comment || prev?.isCompactMode != config.isCompactMode || prev?.showCommentField != config.showCommentField || prev?.includeDateTag != config.includeDateTag || prev?.isFocusedComment != config.isFocusedComment || prev?.waveformVideoEnabled != config.waveformVideoEnabled {
            updateCommentSection(config: config)
        }

        // Badges
        updateBadges(config: config)

        // Selection border
        if isFirstConfigure || prev?.isSelected != config.isSelected {
            updateSelectionBorder(isSelected: config.isSelected)
        }

        // Context menu — only rebuild when needed
        if isFirstConfigure || prev?.status != config.status {
            self.menu = buildContextMenu(config: config)
        }

        self.currentConfig = config
    }

    // MARK: - Layout Updates

    override func layout() {
        super.layout()
        // Update border paths
        let cardBounds = cardView.bounds
        let path = CGPath(roundedRect: cardBounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        selectionBorderLayer.path = path
        selectionBorderLayer.frame = cardBounds

        let thumbBounds = thumbnailContainer.bounds
        let thumbPath = CGPath(roundedRect: thumbBounds, cornerWidth: isCompact ? 6 : 9, cornerHeight: isCompact ? 6 : 9, transform: nil)
        thumbnailBorderLayer.path = thumbPath
        thumbnailBorderLayer.frame = thumbBounds
        checkerboardLayer.frame = thumbBounds

        // Position encoding group accent bar on left edge
        groupAccentLayer.frame = CGRect(x: 0, y: 4, width: 2, height: cardBounds.height - 8)
    }

    override func updateLayer() {
        super.updateLayer()
        if currentConfig?.isGroupChild == true {
            // Subtle blue-tinted background to visually tie child rows to their encoding group header
            cardView.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.17, alpha: 1.0).cgColor
        } else {
            cardView.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1.0).cgColor
        }
    }

    private func updateThumbnailSize() {
        for constraint in thumbnailContainer.constraints {
            if constraint.identifier == "thumbnailWidth" {
                constraint.constant = thumbnailWidth
            }
        }
    }

    private func updateSelectionBorder(isSelected: Bool) {
        selectionBorderLayer.strokeColor = isSelected
            ? NSColor(red: 0.95, green: 0.25, blue: 0.40, alpha: 0.9).cgColor
            : NSColor(red: 0.85, green: 0.25, blue: 0.35, alpha: 0.6).cgColor
        selectionBorderLayer.lineWidth = isSelected ? 3 : 1.2
    }

    private func updateProgressBar(config: VideoFileCellConfiguration) {
        let isActive = config.status == .converting
            || config.isDownloading
            || config.uploadStatus == .uploading
            || config.subtitleStatus.isInProgress
            || config.analyticsStatus.isInProgress

        if isActive {
            progressBar.isHidden = false
            let isPreparing = (config.isDownloading && !config.downloadHasProgress)
                || config.isLiveStreamRecording
            if isPreparing {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            } else {
                progressBar.isIndeterminate = false
                progressBar.stopAnimation(nil)
                progressBar.doubleValue = progressBarValue(config: config)
            }
            // Tint progress bar to match the active process color
            tintProgressBar(config: config)
        } else {
            progressBar.isHidden = true
            progressBar.stopAnimation(nil)
            progressBar.contentFilters = []
        }
    }

    private func tintProgressBar(config: VideoFileCellConfiguration) {
        let tintColor: NSColor
        if config.isDownloading {
            tintColor = .systemPurple
        } else if config.status == .converting {
            tintColor = .systemGreen
        } else if config.subtitleStatus.isInProgress {
            tintColor = .systemYellow
        } else if config.analyticsStatus.isInProgress {
            tintColor = .systemCyan
        } else if config.uploadStatus == .uploading {
            tintColor = .systemBlue
        } else {
            progressBar.contentFilters = []
            return
        }
        if let filter = CIFilter(name: "CIFalseColor") {
            filter.setValue(CIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1), forKey: "inputColor0")
            filter.setValue(CIColor(color: tintColor), forKey: "inputColor1")
            progressBar.contentFilters = [filter]
        }
    }

    private func progressBarValue(config: VideoFileCellConfiguration) -> Double {
        if config.isDownloading { return config.downloadProgress }
        if config.uploadStatus == .uploading { return config.uploadProgress }
        if config.subtitleStatus.isInProgress { return config.subtitleProgress }
        if config.analyticsStatus.isInProgress { return config.analyticsProgress }
        return config.progress
    }

    // MARK: - Display Output Filename

    private func displayOutputFilename(config: VideoFileCellConfiguration) -> String {
        if let override = config.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let ext = config.preset.outputExtension(for: config.url)
            return override + "." + ext
        }
        if let outputURL = config.outputURL {
            return outputURL.lastPathComponent
        }
        let filename = (config.name as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(filename)
        let ext = config.preset.outputExtension(for: config.url)
        let suffix = FileNameProcessor.includePresetSuffix ? config.preset.fileSuffix : ""
        return "\(sanitized)\(suffix).\(ext)"
    }

    // MARK: - Button Actions

    @objc private func deleteButtonClicked() { actionHandler?(.delete) }
    @objc private func resetButtonClicked() {
        let optionPressed = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.reset(optionKeyPressed: optionPressed))
    }
    @objc private func cancelButtonClicked() { actionHandler?(.cancel) }
    @objc private func stopDownloadClicked() { actionHandler?(.stopLiveRecording) }
    @objc private func cancelDownloadClicked() { actionHandler?(.cancelDownload) }
    @objc private func cancelScheduledClicked() { actionHandler?(.cancelScheduledDownload) }
    @objc private func retryDownloadClicked() { actionHandler?(.retryDownload) }
    @objc private func redownloadClicked() { actionHandler?(.forceRedownload) }
    @objc private func cancelSubtitleClicked() { actionHandler?(.cancelSubtitleGeneration) }
    @objc private func cancelAnalyticsClicked() { actionHandler?(.cancelAnalytics) }
    @objc private func downloadedFinderButtonClicked() {
        actionHandler?(.showDownloadedInFinder)
    }
    @objc private func finderButtonClicked() {
        guard let config = currentConfig else { return }
        if config.status == .done, let url = config.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([config.url])
        }
    }

    @objc private func uploadButtonClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.toggleUpload(optionPressed: opt))
    }
    @objc private func transcriptionButtonClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.toggleTranscription(optionPressed: opt))
    }
    @objc private func ocrButtonClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.toggleOCR(optionPressed: opt))
    }
    @objc private func analyticsButtonClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.toggleAnalytics(optionPressed: opt))
    }
    @objc private func encodeButtonClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.encodeNow(optionPressed: opt))
    }
    @objc private func autoEncodeButtonClicked() { actionHandler?(.toggleAutoEncode) }
    @objc func commentToggleClicked() {
        let key = "showCommentField"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    // MARK: - NSTextFieldDelegate (comment field)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === commentField else { return }
        actionHandler?(.commentChanged(field.stringValue))
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === commentField else { return }
        actionHandler?(.commentFocusChanged(true))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === commentField else { return }
        actionHandler?(.commentFocusChanged(false))
    }

    // MARK: - Double-click for output name editing

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 && outputNameLabel.frame.contains(location) {
            actionHandler?(.beginRename)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Badge View

/// Small overlay badge for thumbnail corners (trim, crop, audio routing, etc.)
/// Rendered at full size and scaled down for normal display; scales to 1.0 on hover for crisp text.
/// Clickable — set `onClick` to handle taps.
final class BadgeView: NSView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    /// Anchor point for scale transforms — set per-badge to match its corner position.
    var cornerAnchor = CGPoint(x: 0, y: 0) {
        didSet { needsLayout = true }
    }

    /// Scale when not hovered
    static let restScale: CGFloat = 0.7

    private let effectBackground = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        // Liquid glass background
        effectBackground.material = .hudWindow
        effectBackground.blendingMode = .withinWindow
        effectBackground.state = .active
        effectBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectBackground)
        NSLayoutConstraint.activate([
            effectBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectBackground.topAnchor.constraint(equalTo: topAnchor),
            effectBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Subtle glass edge border
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Rendered at full size — icon 14pt, text 12pt, height 24
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .white
        addSubview(iconView)

        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.textColor = .white
        textLabel.isBezeled = false
        textLabel.isEditable = false
        textLabel.drawsBackground = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 24),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(badgeClicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Position the anchor at the badge's corner so it scales toward/away from that corner
        layer?.anchorPoint = cornerAnchor
        layer?.position = CGPoint(
            x: frame.origin.x + bounds.width * cornerAnchor.x,
            y: frame.origin.y + bounds.height * cornerAnchor.y
        )
    }

    @objc private func badgeClicked() {
        onClick?()
    }

    func update(icon: String, text: String, color: NSColor = .white) {
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = color
        textLabel.stringValue = text
        textLabel.isHidden = text.isEmpty
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    func animateScale(to scale: CGFloat, duration: TimeInterval = 0.2) {
        guard !isHidden else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func showHoverOutline() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        CATransaction.commit()
    }

    func hideHoverOutline() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        CATransaction.commit()
    }
}

// MARK: - DraggableFileImageView

/// Marker NSImageView subclass that holds a file URL for drag-to-share.
/// The actual drag session is initiated by VideoQueueNSTableView, which
/// detects clicks on this view and starts the file drag from the table level
/// (bypassing NSTableView's row-reorder machinery).
final class DraggableFileImageView: NSImageView {
    var fileURL: URL?
}
