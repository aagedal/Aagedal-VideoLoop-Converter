// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Pure AppKit cell view for an encoding group header.
/// Mirrors VideoFileCellView's card layout — same thumbnail area + shadow + corner radius — so
/// groups read as peers of single items. The thumbnail area uses a stacked-thumbnail preview
/// that signals "this is a group of items"; the selection border is dashed at rest and solid
/// + system-blue when selected. When expanded, child items render as compact mini-rows inside
/// the group's card rather than as separate table rows.
final class EncodingGroupHeaderCellView: NSTableCellView, NSTextFieldDelegate {

    static let baseRowHeight: CGFloat = 170
    static let baseCompactRowHeight: CGFloat = 120

    /// Computes the total row height the table view should reserve for this group.
    /// Groups are now single-height summary cards — expand/collapse was removed
    /// when detail editing moved to the standalone Group Editor window.
    static func rowHeight(for config: EncodingGroupCellConfiguration) -> CGFloat {
        config.isCompactMode ? baseCompactRowHeight : baseRowHeight
    }

    // MARK: - Cached SF Symbols (group-header-specific)

    private enum GroupSymbol {
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
        static let playCircle       = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
        static let checkmarkCircle  = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        static let xmarkCircle      = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        static let arrowDownCircle  = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        static let clock            = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
    }

    // MARK: - State

    private(set) var currentGroupID: UUID?
    var actionHandler: ((CellAction) -> Void)?
    private var currentConfig: EncodingGroupCellConfiguration?

    // MARK: - Subviews

    private let cardView = NSView()
    private let selectionBorderLayer = CAShapeLayer()

    private let mainHStack = NSStackView()

    // Thumbnail area (left)
    private let thumbnailContainer = NSView()
    private let thumbnailBorderLayer = CAShapeLayer()
    private let stackedThumb1 = NSImageView()   // back
    private let stackedThumb2 = NSImageView()   // middle
    private let stackedThumb3 = NSImageView()   // front (primary)
    private let emptyFolderIcon = NSImageView()
    private let childCountBadge = NSTextField(labelWithString: "")

    // Right side: content
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
    private let folderIcon = NSImageView()
    private let nameField = NSTextField()
    private let clipCountLabel = NSTextField(labelWithString: "")
    private let concatOutputButton = NSButton()
    private let concatDragButton = DraggableFileImageView()
    private let concatWarningButton = NSButton()
    private let addFilesButton = NSButton()
    private let editButton = NSButton()
    private let sortButton = NSButton()
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
    private var thumbnailWidthConstraint: NSLayoutConstraint?
    private var thumbnailHeightConstraint: NSLayoutConstraint?
    private var checkerHeightConstraint: NSLayoutConstraint?

    // Layout cache
    private var lastCardBoundsSize: CGSize = .zero
    private var lastThumbBoundsSize: CGSize = .zero
    private var isCompact = false

    private var thumbnailWidth: CGFloat { isCompact ? 160 : 240 }

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

        // Selection border — dashed at rest, solid + system-blue on selection. Idle dash is a
        // muted neutral so it reads as "container" without competing with VideoItem selection.
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        selectionBorderLayer.lineWidth = 1.2
        selectionBorderLayer.lineDashPattern = [6, 4]
        selectionBorderLayer.zPosition = 100
        cardView.layer?.addSublayer(selectionBorderLayer)

        // Main horizontal stack: thumbnail | content
        mainHStack.orientation = .horizontal
        mainHStack.spacing = 0
        mainHStack.alignment = .top
        mainHStack.distribution = .fill
        mainHStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(mainHStack)

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

        setupThumbnailArea()
        setupContentArea()
    }

    // MARK: - Thumbnail area

    private func setupThumbnailArea() {
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.masksToBounds = true
        thumbnailContainer.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        thumbnailContainer.layer?.cornerRadius = 8

        // Checkerboard background — pinned to thumbnail container so it tracks the compact width.
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
        let checkerHeight = checkerView.heightAnchor.constraint(equalToConstant: Self.baseRowHeight - 12)
        self.checkerHeightConstraint = checkerHeight

        // Stacked thumbnail layers — back → middle → front, slight offsets create the "stack" feel.
        for (i, view) in [stackedThumb1, stackedThumb2, stackedThumb3].enumerated() {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            view.layer?.cornerRadius = 6
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            thumbnailContainer.addSubview(view)
            // Slight darkening for back/mid layers so the stack reads front-to-back.
            view.alphaValue = i == 0 ? 0.55 : (i == 1 ? 0.8 : 1.0)
        }

        // Fallback folder icon, shown when there are no children at all.
        emptyFolderIcon.image = GroupSymbol.folderFill
        emptyFolderIcon.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.75)
        emptyFolderIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyFolderIcon.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(emptyFolderIcon)

        // Child count badge (bottom-right of thumbnail) — always shown when itemCount > 1.
        childCountBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        childCountBadge.textColor = .white
        childCountBadge.isBezeled = false
        childCountBadge.isEditable = false
        childCountBadge.drawsBackground = true
        childCountBadge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        childCountBadge.alignment = .center
        childCountBadge.wantsLayer = true
        childCountBadge.layer?.cornerRadius = 10
        childCountBadge.layer?.masksToBounds = true
        childCountBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(childCountBadge)

        // Border over the entire thumbnail container
        thumbnailBorderLayer.fillColor = nil
        thumbnailBorderLayer.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailBorderLayer.lineWidth = 1
        thumbnailContainer.layer?.addSublayer(thumbnailBorderLayer)

        mainHStack.addArrangedSubview(thumbnailContainer)

        let widthConstraint = thumbnailContainer.widthAnchor.constraint(equalToConstant: thumbnailWidth)
        widthConstraint.identifier = "groupThumbnailWidth"
        self.thumbnailWidthConstraint = widthConstraint

        // Thumbnail only spans the BASE row region; the expanded children live below.
        let heightConstraint = thumbnailContainer.heightAnchor.constraint(equalToConstant: Self.baseRowHeight - 12)
        self.thumbnailHeightConstraint = heightConstraint

        // Now that thumbnailContainer has a superview, its width anchor can be bound to
        // the checkerView's width anchor (they share `cardView` as a common ancestor).
        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            thumbnailContainer.topAnchor.constraint(equalTo: mainHStack.topAnchor),

            checkerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            checkerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            checkerHeight,
            checkerView.widthAnchor.constraint(equalTo: thumbnailContainer.widthAnchor),
        ])

        // Position stacked thumbnails and fallback folder icon relative to the container.
        // Back layer is nudged up-left, middle slightly less so, front is flush to (left + 12, center).
        // Each layer gets ~68% of the container width so they clearly overlap.
        let inset: CGFloat = 12
        let backOffset: CGFloat = 16
        let midOffset: CGFloat = 8

        NSLayoutConstraint.activate([
            // stackedThumb1 (back)
            stackedThumb1.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset + backOffset),
            stackedThumb1.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset + backOffset),
            stackedThumb1.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset),
            stackedThumb1.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset),

            // stackedThumb2 (middle)
            stackedThumb2.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset + midOffset),
            stackedThumb2.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset + midOffset),
            stackedThumb2.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset - backOffset + midOffset),
            stackedThumb2.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset - backOffset + midOffset),

            // stackedThumb3 (front, primary)
            stackedThumb3.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset),
            stackedThumb3.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset),
            stackedThumb3.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset - backOffset),
            stackedThumb3.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset - backOffset),

            // Empty folder icon
            emptyFolderIcon.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            emptyFolderIcon.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
            emptyFolderIcon.widthAnchor.constraint(equalToConstant: 40),
            emptyFolderIcon.heightAnchor.constraint(equalToConstant: 40),

            // Child count badge, bottom-right corner
            childCountBadge.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -6),
            childCountBadge.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -6),
            childCountBadge.heightAnchor.constraint(equalToConstant: 20),
            childCountBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
    }

    // MARK: - Content area

    private func setupContentArea() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        setupTopRow()
        setupBottomRow()
        setupProgressBar()
        setupUploadRow()

        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(progressBar)
        contentStack.addArrangedSubview(bottomRow)
        contentStack.addArrangedSubview(uploadRow)

        // Wrap contentStack in a padded container, matching VideoFileCellView's right column.
        let contentPadding = NSView()
        contentPadding.translatesAutoresizingMaskIntoConstraints = false
        contentPadding.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentPadding.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: contentPadding.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentPadding.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentPadding.bottomAnchor, constant: -8),

            topRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            progressBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            uploadRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            uploadRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])

        mainHStack.addArrangedSubview(contentPadding)
        contentPadding.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func setupTopRow() {
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

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

        // Opens the standalone editor window where reorder/remove/extract happen.
        // Keeps the main queue focused on high-level queue manipulation.
        configureBorderlessButton(editButton, symbol: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit group contents"), tint: .systemBlue, action: #selector(editClicked))
        editButton.toolTip = "Edit group contents (reorder, remove, rename)"

        configureBorderlessButton(sortButton, symbol: NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort items in group"), tint: .secondaryLabelColor, action: #selector(sortClicked))
        sortButton.toolTip = "Sort items in group (cycle: filename A–Z, Z–A, date old→new, new→old)"

        configureBorderlessButton(resetButton, symbol: GroupSymbol.reset, tint: .secondaryLabelColor, action: #selector(resetClicked))
        resetButton.toolTip = "Reset all items in group"

        configureBorderlessButton(deleteButton, symbol: GroupSymbol.trash, tint: NSColor.systemRed.withAlphaComponent(0.75), action: #selector(deleteClicked))
        deleteButton.toolTip = "Delete group"

        topRow.addArrangedSubview(folderIcon)
        topRow.addArrangedSubview(nameField)
        topRow.addArrangedSubview(clipCountLabel)
        topRow.addArrangedSubview(concatOutputButton)
        topRow.addArrangedSubview(concatDragButton)
        topRow.addArrangedSubview(concatWarningButton)
        topRow.addArrangedSubview(addFilesButton)
        topRow.addArrangedSubview(editButton)
        topRow.addArrangedSubview(sortButton)
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
            thumbnailWidthConstraint?.constant = thumbnailWidth
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

        if isFirstConfigure
            || prev?.isSelected != config.isSelected
            || prev?.isDropTargetHover != config.isDropTargetHover {
            updateSelectionBorder(isSelected: config.isSelected, isDropTargetHover: config.isDropTargetHover)
        }

        if isFirstConfigure || prev?.stackedChildren != config.stackedChildren {
            updateStackedThumbnails(config: config)
        }

        if isFirstConfigure || prev?.itemCount != config.itemCount {
            updateChildCountBadge(count: config.itemCount)
        }

        self.currentConfig = config
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastCardBoundsSize = .zero
        lastThumbBoundsSize = .zero
    }

    /// Called by the coordinator when a child's thumbnail data finishes decoding
    /// off-main. Updates the stacked-preview slots that reference that child.
    func applyDecodedChildThumbnail(_ image: NSImage?, forItemID itemID: UUID) {
        guard let config = currentConfig else { return }
        for (slot, child) in config.stackedChildren.prefix(3).enumerated() where child.itemID == itemID {
            switch slot {
            case 0: stackedThumb3.image = image
            case 1: stackedThumb2.image = image
            case 2: stackedThumb1.image = image
            default: break
            }
        }
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

        let thumbBounds = thumbnailContainer.bounds
        if thumbBounds.size != lastThumbBoundsSize {
            let path = CGPath(roundedRect: thumbBounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
            thumbnailBorderLayer.path = path
            thumbnailBorderLayer.frame = thumbBounds
            lastThumbBoundsSize = thumbBounds.size
        }
    }

    private func applyCompactLayout(_ compact: Bool) {
        contentStack.spacing = compact ? 4 : 8
        presetWidthConstraint?.constant = compact ? 140 : 220
        let baseHeight = (compact ? Self.baseCompactRowHeight : Self.baseRowHeight) - 12
        thumbnailHeightConstraint?.constant = baseHeight
        checkerHeightConstraint?.constant = baseHeight
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

    private func updateSelectionBorder(isSelected: Bool, isDropTargetHover: Bool) {
        // Drop-target hover wins over selection so the user can see exactly where a
        // dragged item will land. Uses a bright, thick, solid blue — distinct from
        // the dimmer selection border so the two states read differently.
        if isDropTargetHover {
            selectionBorderLayer.strokeColor = NSColor.systemBlue.cgColor
            selectionBorderLayer.lineWidth = 3
            selectionBorderLayer.lineDashPattern = nil
        } else if isSelected {
            selectionBorderLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            selectionBorderLayer.lineWidth = 2.5
            selectionBorderLayer.lineDashPattern = nil
        } else {
            selectionBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
            selectionBorderLayer.lineWidth = 1.2
            selectionBorderLayer.lineDashPattern = [6, 4]
        }
    }

    private func updateStackedThumbnails(config: EncodingGroupCellConfiguration) {
        let children = Array(config.stackedChildren.prefix(3))

        // Reset all three slots first.
        stackedThumb1.image = nil
        stackedThumb2.image = nil
        stackedThumb3.image = nil

        let visibleCount = children.count
        stackedThumb1.isHidden = visibleCount < 3
        stackedThumb2.isHidden = visibleCount < 2
        stackedThumb3.isHidden = visibleCount < 1
        emptyFolderIcon.isHidden = visibleCount > 0

        // Front → back mapping: first child goes to front (stackedThumb3), next to middle, last to back.
        for (slot, child) in children.enumerated() {
            let cached = ThumbnailCache.shared[child.itemID]
            let view: NSImageView
            switch slot {
            case 0: view = stackedThumb3
            case 1: view = stackedThumb2
            case 2: view = stackedThumb1
            default: continue
            }
            view.image = cached
        }
    }

    private func updateChildCountBadge(count: Int) {
        childCountBadge.isHidden = count <= 1
        if count > 1 {
            childCountBadge.stringValue = "  \(count) clips  "
        }
    }

    // MARK: - Actions

    @objc private func addFilesClicked() { actionHandler?(.addFilesToGroup) }
    @objc private func editClicked() { actionHandler?(.openGroupEditor) }
    @objc private func sortClicked() { actionHandler?(.cycleGroupSort) }
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
