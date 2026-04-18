// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Pure AppKit cell view for an encoding group header.
/// Replaces the SwiftUI EncodingGroupHeaderView so the NSTableView scroll
/// hot path stays AppKit-only (no NSHostingView / SwiftUI body rebuilds).
final class EncodingGroupHeaderCellView: NSTableCellView, NSTextFieldDelegate {

    // MARK: - Cached SF Symbols (group-header-specific)

    private enum GroupSymbol {
        static let chevronDown      = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        static let chevronRight     = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        static let folderFill       = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        static let plus             = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        static let reset            = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        static let trash            = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        static let numberCircleFill = NSImage(systemSymbolName: "number.circle.fill", accessibilityDescription: nil)
        static let numberCircle     = NSImage(systemSymbolName: "number.circle", accessibilityDescription: nil)
        static let concat           = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)
        static let finderCircle     = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: nil)
        static let dragHandle       = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
        static let uploadedCheck    = NSImage(systemSymbolName: "checkmark.icloud.fill", accessibilityDescription: nil)
        static let uploadFailed     = NSImage(systemSymbolName: "exclamationmark.icloud.fill", accessibilityDescription: nil)
        static let uploadPending    = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
    }

    // MARK: - State

    private(set) var currentGroupID: UUID?
    var actionHandler: ((CellAction) -> Void)?
    private var currentConfig: EncodingGroupCellConfiguration?

    // MARK: - Subviews

    private let cardView = NSView()
    private let selectionBorderLayer = CAShapeLayer()

    private let contentStack = NSStackView()
    private let topRow = NSStackView()
    private let bottomRow = NSStackView()
    private let togglesStack = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let uploadRow = NSStackView()
    private let uploadIcon = NSImageView()
    private let uploadLabel = NSTextField(labelWithString: "")
    private let uploadProgress = NSProgressIndicator()

    // Top row
    private let expandChevronButton = NSButton()
    private let folderIcon = NSImageView()
    private let nameField = NSTextField()
    private let clipCountLabel = NSTextField(labelWithString: "")
    private let concatOutputButton = NSButton()
    private let concatDragButton = DraggableFileImageView()
    private let concatWarningButton = NSButton()
    private let addFilesButton = NSButton()
    private let resetButton = NSButton()
    private let deleteButton = NSButton()

    // Bottom row
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sequentialToggle = NSButton()
    private let concatToggle = NSButton()
    private let uploadToggle = NSButton()
    private let transcriptionToggle = NSButton()
    private let analyticsToggle = NSButton()

    private var presetWidthConstraint: NSLayoutConstraint?

    // Layout cache
    private var lastCardBoundsSize: CGSize = .zero
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

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.lineWidth = 0.8
        selectionBorderLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        selectionBorderLayer.zPosition = 100
        cardView.layer?.addSublayer(selectionBorderLayer)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -10),
        ])

        setupTopRow()
        setupBottomRow()
        setupProgressBar()
        setupUploadRow()

        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(bottomRow)
        contentStack.addArrangedSubview(progressBar)
        contentStack.addArrangedSubview(uploadRow)

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            progressBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            uploadRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            uploadRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
    }

    private func setupTopRow() {
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        configureBorderlessButton(expandChevronButton, symbol: GroupSymbol.chevronRight, tint: .secondaryLabelColor, action: #selector(chevronClicked))
        expandChevronButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        expandChevronButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        folderIcon.image = GroupSymbol.folderFill
        folderIcon.contentTintColor = .systemBlue
        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.placeholderString = "Group name"
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.usesSingleLineMode = true
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.target = self
        nameField.action = #selector(nameFieldCommitted)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clipCountLabel.font = .systemFont(ofSize: 12)
        clipCountLabel.textColor = .secondaryLabelColor
        clipCountLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        clipCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureBorderlessButton(concatOutputButton, symbol: GroupSymbol.finderCircle, tint: .systemBlue, action: #selector(concatOutputFinderClicked))
        concatOutputButton.toolTip = "Show merged output in Finder"

        concatDragButton.image = GroupSymbol.dragHandle
        concatDragButton.contentTintColor = .systemBlue
        concatDragButton.imageScaling = .scaleProportionallyUpOrDown
        concatDragButton.toolTip = "Drag to share the merged file"
        concatDragButton.translatesAutoresizingMaskIntoConstraints = false
        concatDragButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        concatDragButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        configureBorderlessButton(concatWarningButton, symbol: GroupSymbol.finderCircle, tint: .systemOrange, action: #selector(concatWarningClicked))
        concatWarningButton.toolTip = "Output file already exists and will be overwritten. Click to show in Finder."

        configureBorderlessButton(addFilesButton, symbol: GroupSymbol.plus, tint: .secondaryLabelColor, action: #selector(addFilesClicked))
        addFilesButton.toolTip = "Add files to group"

        configureBorderlessButton(resetButton, symbol: GroupSymbol.reset, tint: .secondaryLabelColor, action: #selector(resetClicked))
        resetButton.toolTip = "Reset all items in group"

        configureBorderlessButton(deleteButton, symbol: GroupSymbol.trash, tint: NSColor.systemRed.withAlphaComponent(0.75), action: #selector(deleteClicked))
        deleteButton.toolTip = "Delete group"

        topRow.addArrangedSubview(expandChevronButton)
        topRow.addArrangedSubview(folderIcon)
        topRow.addArrangedSubview(nameField)
        topRow.addArrangedSubview(clipCountLabel)
        topRow.addArrangedSubview(concatOutputButton)
        topRow.addArrangedSubview(concatDragButton)
        topRow.addArrangedSubview(concatWarningButton)
        topRow.addArrangedSubview(addFilesButton)
        topRow.addArrangedSubview(resetButton)
        topRow.addArrangedSubview(deleteButton)
    }

    private func setupBottomRow() {
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12
        bottomRow.distribution = .fill
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.controlSize = .small
        presetPopup.font = .systemFont(ofSize: 11)
        presetPopup.target = self
        presetPopup.action = #selector(presetSelected(_:))
        let width = presetPopup.widthAnchor.constraint(equalToConstant: 220)
        width.isActive = true
        presetWidthConstraint = width

        togglesStack.orientation = .horizontal
        togglesStack.alignment = .centerY
        togglesStack.spacing = 4
        togglesStack.translatesAutoresizingMaskIntoConstraints = false

        configureToggleButton(sequentialToggle, onSymbol: GroupSymbol.numberCircleFill, offSymbol: GroupSymbol.numberCircle, action: #selector(sequentialClicked))
        configureToggleButton(concatToggle, onSymbol: GroupSymbol.concat, offSymbol: GroupSymbol.concat, action: #selector(concatClicked))
        configureToggleButton(uploadToggle, onSymbol: VideoFileCellView.Symbol.cloudArrowUpFill, offSymbol: VideoFileCellView.Symbol.cloudArrowUp, action: #selector(uploadClicked))
        configureToggleButton(transcriptionToggle, onSymbol: VideoFileCellView.Symbol.captionsBubbleFill, offSymbol: VideoFileCellView.Symbol.captionsBubble, action: #selector(transcriptionClicked))
        configureToggleButton(analyticsToggle, onSymbol: VideoFileCellView.Symbol.chartAscending, offSymbol: VideoFileCellView.Symbol.chartBase, action: #selector(analyticsClicked))

        togglesStack.addArrangedSubview(sequentialToggle)
        togglesStack.addArrangedSubview(concatToggle)
        togglesStack.addArrangedSubview(uploadToggle)
        togglesStack.addArrangedSubview(transcriptionToggle)
        togglesStack.addArrangedSubview(analyticsToggle)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bottomRow.addArrangedSubview(presetPopup)
        bottomRow.addArrangedSubview(spacer)
        bottomRow.addArrangedSubview(togglesStack)
    }

    private func setupProgressBar() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        progressBar.isHidden = true
    }

    private func setupUploadRow() {
        uploadRow.orientation = .horizontal
        uploadRow.alignment = .centerY
        uploadRow.spacing = 6
        uploadRow.translatesAutoresizingMaskIntoConstraints = false

        uploadIcon.imageScaling = .scaleProportionallyUpOrDown
        uploadIcon.translatesAutoresizingMaskIntoConstraints = false
        uploadIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        uploadIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        uploadLabel.font = .systemFont(ofSize: 11)
        uploadLabel.textColor = .secondaryLabelColor

        uploadProgress.style = .bar
        uploadProgress.isIndeterminate = false
        uploadProgress.minValue = 0
        uploadProgress.maxValue = 1
        uploadProgress.controlSize = .small
        uploadProgress.translatesAutoresizingMaskIntoConstraints = false
        uploadProgress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        uploadProgress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        uploadRow.addArrangedSubview(uploadIcon)
        uploadRow.addArrangedSubview(uploadLabel)
        uploadRow.addArrangedSubview(uploadProgress)
        uploadRow.isHidden = true
    }

    private func configureBorderlessButton(_ button: NSButton, symbol: NSImage?, tint: NSColor, action: Selector) {
        button.image = symbol
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
    }

    private func configureToggleButton(_ button: NSButton, onSymbol: NSImage?, offSymbol: NSImage?, action: Selector) {
        button.image = offSymbol
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    // MARK: - Configure

    func configure(with config: EncodingGroupCellConfiguration, actionHandler: @escaping (CellAction) -> Void) {
        let prev = self.currentConfig
        self.actionHandler = actionHandler

        if let prev, prev == config { return }

        let isFirstConfigure = prev == nil || prev?.groupID != config.groupID
        self.currentGroupID = config.groupID

        if isFirstConfigure || prev?.isCompactMode != config.isCompactMode {
            isCompact = config.isCompactMode
            applyCompactLayout(config.isCompactMode)
        }

        if isFirstConfigure || prev?.isExpanded != config.isExpanded {
            expandChevronButton.image = config.isExpanded ? GroupSymbol.chevronDown : GroupSymbol.chevronRight
        }

        if isFirstConfigure || prev?.name != config.name {
            if nameField.stringValue != config.name {
                nameField.stringValue = config.name
            }
        }

        if isFirstConfigure || prev?.itemCount != config.itemCount || prev?.totalDuration != config.totalDuration {
            clipCountLabel.stringValue = clipCountText(count: config.itemCount, duration: config.totalDuration)
        }

        if isFirstConfigure
            || prev?.concatOutputURL != config.concatOutputURL
            || prev?.concatOutputAlreadyExists != config.concatOutputAlreadyExists
            || prev?.concatOutputExistingURL != config.concatOutputExistingURL {
            updateConcatOutputIcons(config: config)
        }

        if isFirstConfigure
            || prev?.globalPreset != config.globalPreset
            || prev?.groupPreset != config.groupPreset {
            rebuildPresetPopup(config: config)
        }

        if isFirstConfigure
            || prev?.sequentialNamingEnabled != config.sequentialNamingEnabled
            || prev?.name != config.name {
            updateSequentialToggle(config: config)
        }

        if isFirstConfigure || prev?.concatEnabled != config.concatEnabled {
            updateConcatToggle(config: config)
        }

        if isFirstConfigure
            || prev?.uploadEnabled != config.uploadEnabled
            || prev?.isUploadConfigured != config.isUploadConfigured {
            updateUploadToggle(config: config)
        }

        if isFirstConfigure || prev?.transcriptionEnabled != config.transcriptionEnabled {
            updateTranscriptionToggle(config: config)
        }

        if isFirstConfigure || prev?.analyticsEnabled != config.analyticsEnabled {
            updateAnalyticsToggle(config: config)
        }

        if isFirstConfigure
            || prev?.status != config.status
            || prev?.progress != config.progress
            || prev?.isCompactMode != config.isCompactMode {
            updateProgressBar(config: config)
        }

        if isFirstConfigure
            || prev?.uploadSummary != config.uploadSummary
            || prev?.isCompactMode != config.isCompactMode {
            updateUploadSummary(config: config)
        }

        if isFirstConfigure || prev?.isSelected != config.isSelected {
            updateSelectionBorder(isSelected: config.isSelected)
        }

        self.currentConfig = config
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastCardBoundsSize = .zero
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let cardBounds = cardView.bounds
        if cardBounds.size != lastCardBoundsSize {
            let path = CGPath(roundedRect: cardBounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
            selectionBorderLayer.path = path
            selectionBorderLayer.frame = cardBounds
            lastCardBoundsSize = cardBounds.size
        }
    }

    private func applyCompactLayout(_ compact: Bool) {
        contentStack.spacing = compact ? 4 : 8
        presetWidthConstraint?.constant = compact ? 140 : 220
        folderIcon.isHidden = compact
    }

    // MARK: - Sub-updates

    private func clipCountText(count: Int, duration: String) -> String {
        guard count > 0 else { return "Empty group" }
        let clipText = count == 1 ? "1 clip" : "\(count) clips"
        if duration.isEmpty { return clipText }
        return "\(clipText) · \(duration)"
    }

    private func updateConcatOutputIcons(config: EncodingGroupCellConfiguration) {
        let showDone = config.concatOutputURL != nil
        concatOutputButton.isHidden = !showDone
        concatDragButton.isHidden = !showDone
        concatDragButton.fileURL = config.concatOutputURL

        let showWarning = config.concatOutputAlreadyExists
        concatWarningButton.isHidden = !showWarning
    }

    private func rebuildPresetPopup(config: EncodingGroupCellConfiguration) {
        let manager = PresetManager.shared
        presetPopup.removeAllItems()

        let globalLabel = "Global (\(manager.displayName(for: config.globalPreset)))"
        let globalItem = NSMenuItem(title: globalLabel, action: nil, keyEquivalent: "")
        globalItem.representedObject = nil as ExportPreset?
        presetPopup.menu?.addItem(globalItem)
        presetPopup.menu?.addItem(.separator())

        for preset in manager.visiblePresets {
            let item = NSMenuItem(title: manager.displayName(for: preset), action: nil, keyEquivalent: "")
            item.representedObject = preset
            presetPopup.menu?.addItem(item)
        }

        if let selected = config.groupPreset,
           let item = presetPopup.menu?.items.first(where: { ($0.representedObject as? ExportPreset) == selected }) {
            presetPopup.select(item)
        } else {
            presetPopup.selectItem(at: 0)
        }
    }

    private func updateSequentialToggle(config: EncodingGroupCellConfiguration) {
        sequentialToggle.image = config.sequentialNamingEnabled ? GroupSymbol.numberCircleFill : GroupSymbol.numberCircle
        sequentialToggle.contentTintColor = config.sequentialNamingEnabled ? .systemBlue : .secondaryLabelColor
        sequentialToggle.toolTip = config.sequentialNamingEnabled
            ? "Sequential naming enabled — files named \(config.name)_001, \(config.name)_002, …"
            : "Enable sequential naming using group name"
    }

    private func updateConcatToggle(config: EncodingGroupCellConfiguration) {
        concatToggle.image = GroupSymbol.concat
        concatToggle.contentTintColor = config.concatEnabled ? .systemBlue : .secondaryLabelColor
        concatToggle.toolTip = config.concatEnabled
            ? "Concat enabled — clips will be merged into one file"
            : "Enable concat to merge clips into one file"
    }

    private func updateUploadToggle(config: EncodingGroupCellConfiguration) {
        uploadToggle.image = config.uploadEnabled
            ? VideoFileCellView.Symbol.cloudArrowUpFill
            : VideoFileCellView.Symbol.cloudArrowUp
        uploadToggle.contentTintColor = config.uploadEnabled ? .systemBlue : .secondaryLabelColor
        uploadToggle.isEnabled = config.isUploadConfigured
        uploadToggle.toolTip = config.isUploadConfigured
            ? (config.uploadEnabled ? "Upload enabled — files will upload after encoding" : "Enable upload after encoding")
            : "Configure upload in Settings → Upload"
    }

    private func updateTranscriptionToggle(config: EncodingGroupCellConfiguration) {
        transcriptionToggle.image = config.transcriptionEnabled
            ? VideoFileCellView.Symbol.captionsBubbleFill
            : VideoFileCellView.Symbol.captionsBubble
        transcriptionToggle.contentTintColor = config.transcriptionEnabled ? .systemGreen : .secondaryLabelColor
        transcriptionToggle.toolTip = config.transcriptionEnabled
            ? "Transcription enabled — SRT will be created after encoding"
            : "Enable transcription for subtitle generation"
    }

    private func updateAnalyticsToggle(config: EncodingGroupCellConfiguration) {
        analyticsToggle.image = config.analyticsEnabled
            ? VideoFileCellView.Symbol.chartAscending
            : VideoFileCellView.Symbol.chartBase
        analyticsToggle.contentTintColor = config.analyticsEnabled ? .systemCyan : .secondaryLabelColor
        analyticsToggle.toolTip = config.analyticsEnabled
            ? "Quality analytics enabled — will run after encoding"
            : "Enable quality analytics after encoding"
    }

    private func updateProgressBar(config: EncodingGroupCellConfiguration) {
        let active = config.status == .converting && !config.isCompactMode
        progressBar.isHidden = !active
        if active {
            progressBar.doubleValue = config.progress
        }
    }

    private func updateUploadSummary(config: EncodingGroupCellConfiguration) {
        if config.isCompactMode {
            uploadRow.isHidden = true
            return
        }
        switch config.uploadSummary {
        case .hidden:
            uploadRow.isHidden = true
        case .uploaded(let count, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadedCheck
            uploadIcon.contentTintColor = .systemGreen
            uploadLabel.stringValue = "Uploaded \(count)/\(total)"
            uploadProgress.isHidden = true
        case .failed(let count, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadFailed
            uploadIcon.contentTintColor = .systemRed
            uploadLabel.stringValue = "Upload failed \(count)/\(total)"
            uploadProgress.isHidden = true
        case .uploading(let completed, let total, let progress, let speed):
            uploadRow.isHidden = false
            uploadIcon.image = VideoFileCellView.Symbol.cloudArrowUp
            uploadIcon.contentTintColor = .systemOrange
            let speedText = speed.map { " · \($0)" } ?? ""
            uploadLabel.stringValue = "Uploading \(completed + 1)/\(total)\(speedText)"
            uploadProgress.isHidden = false
            uploadProgress.doubleValue = progress
        case .pending(let uploaded, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadPending
            uploadIcon.contentTintColor = .systemOrange
            uploadLabel.stringValue = "Upload pending \(uploaded)/\(total)"
            uploadProgress.isHidden = false
            uploadProgress.doubleValue = total > 0 ? Double(uploaded) / Double(total) : 0
        }
    }

    private func updateSelectionBorder(isSelected: Bool) {
        selectionBorderLayer.strokeColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        selectionBorderLayer.lineWidth = isSelected ? 2 : 0.8
    }

    /// Applies a thumbnail-equivalent refresh if needed. (Group headers have no thumbnail;
    /// method kept as a symmetric placeholder to match VideoFileCellView's shape.)
    func applyDecodedThumbnail(_ image: NSImage?, forItemID: UUID) { /* no-op */ }

    // MARK: - Actions

    @objc private func chevronClicked() { actionHandler?(.toggleExpanded) }
    @objc private func addFilesClicked() { actionHandler?(.addFilesToGroup) }
    @objc private func resetClicked() { actionHandler?(.resetGroup) }
    @objc private func deleteClicked() {
        guard let groupName = currentConfig?.name else {
            actionHandler?(.deleteGroup)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete Group"
        alert.informativeText = "This will remove the group \"\(groupName)\" and all its items from the queue."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            actionHandler?(.deleteGroup)
        }
    }

    @objc private func sequentialClicked() { actionHandler?(.toggleSequentialNaming) }
    @objc private func concatClicked() { actionHandler?(.toggleConcat) }
    @objc private func uploadClicked() { actionHandler?(.toggleGroupUpload) }
    @objc private func transcriptionClicked() { actionHandler?(.toggleGroupTranscription) }
    @objc private func analyticsClicked() { actionHandler?(.toggleGroupAnalytics) }

    @objc private func presetSelected(_ sender: NSPopUpButton) {
        let preset = sender.selectedItem?.representedObject as? ExportPreset
        actionHandler?(.setGroupPreset(preset))
    }

    @objc private func concatOutputFinderClicked() {
        if let url = currentConfig?.concatOutputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func concatWarningClicked() {
        if let url = currentConfig?.concatOutputExistingURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func nameFieldCommitted() {
        let newName = nameField.stringValue
        if newName != currentConfig?.name {
            actionHandler?(.groupNameChanged(newName))
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        nameFieldCommitted()
    }
}
