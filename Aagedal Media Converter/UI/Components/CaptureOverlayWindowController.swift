// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureOverlayWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {

    static let shared = CaptureOverlayWindowController()

    private var overlayPanel: NSPanel?
    private var controlPanel: NSPanel?
    private var controlHostingView: NSHostingView<CaptureControlPanelView>?
    private var processingObserver: AnyCancellable?
    private var escapeKeyLocalMonitor: Any?
    private var escapeKeyGlobalMonitor: Any?
    private var modifierKeyLocalMonitor: Any?
    private var modifierKeyGlobalMonitor: Any?

    // Menu bar status item (shown during recording) whose dropdown holds the recording controls.
    private var showPanelStatusItem: NSStatusItem?
    private var statusMenuUpdateTimer: Timer?

    private(set) var isShowing = false

    // Click-through state — when either is true, the region overlay passes mouse events through.
    // The control panel passes events through only while CMD is held, so the toggle button stays usable.
    private var isCmdHeld = false
    private(set) var isRegionOverlayClickThrough = false

    // Base window levels — high enough to sit above other apps. Users can hold CMD or use the
    // toggle button on the control panel to click through to anything underneath (e.g. a TCC dialog).
    private let regionOverlayLevel: NSWindow.Level = .popUpMenu
    private var controlPanelLevelWhenRegionShown: NSWindow.Level {
        .init(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    }
    private let controlPanelLevelWhenAlone: NSWindow.Level = .popUpMenu

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func showCaptureOverlay(on screen: NSScreen? = nil) {
        guard !isShowing else { return }

        // Check screen recording permission before hiding the app.
        if !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() {
                // Permission was already denied previously — CGRequestScreenCaptureAccess()
                // won't show the dialog again, so open System Settings directly.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        isShowing = true

        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            isShowing = false // no active displays — abort the overlay
            return
        }

        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isShowing else { return }
            self.createOverlayPanel(on: targetScreen)
            self.createControlPanel(on: targetScreen)
            self.setupRecordingObservers()
            self.installEscapeKeyMonitor()
            self.installModifierKeyMonitor()
        }
    }

    func dismissCaptureOverlay() {
        guard isShowing else { return }
        isShowing = false

        processingObserver = nil
        removeEscapeKeyMonitor()
        removeModifierKeyMonitor()
        isRegionOverlayClickThrough = false

        let captureManager = ScreenCaptureManager.shared
        Task {
            await captureManager.stopPreview()
        }

        overlayPanel?.close()
        overlayPanel = nil

        controlPanel?.close()
        controlPanel = nil
        controlHostingView = nil
        hideStatusItems()

        NSApp.unhide(nil)
    }

    func hideControlPanel() {
        controlPanel?.orderOut(nil)
        showStatusItems()
    }

    func showControlPanel() {
        controlPanel?.makeKeyAndOrderFront(nil)
        hideStatusItems()
    }

    /// Resizes the floating control panel to match the SwiftUI content's current fitting size
    /// (driven by the user's overlay scale), anchored at the bottom-center so it grows upward and
    /// outward without drifting.
    func resizeControlPanelToFit() {
        guard let panel = controlPanel, let hosting = controlHostingView else { return }
        // Let the hosting view recompute its layout before measuring.
        hosting.layoutSubtreeIfNeeded()
        let newSize = hosting.fittingSize
        guard newSize.width > 0, newSize.height > 0 else { return }
        let oldFrame = panel.frame
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.minY
        )
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
    }

    // MARK: - Recording Lifecycle

    func startRecording() {
        // Dismiss overlay (region selection) so actual screen content is visible
        overlayPanel?.close()
        overlayPanel = nil
        // Show menu bar items so user can stop or re-show panel even if hidden
        showStatusItems()
    }

    func stopRecordingAndShowDialog() {
        Task {
            let captureManager = ScreenCaptureManager.shared
            await captureManager.stopRecording()
        }
    }

    func handleRecordingStopped() {
        let lastURL = ScreenCaptureManager.shared.lastOutputURL

        // Dismiss control panel and status items
        controlPanel?.close()
        controlPanel = nil
        controlHostingView = nil
        overlayPanel?.close()
        overlayPanel = nil
        hideStatusItems()
        removeEscapeKeyMonitor()
        removeModifierKeyMonitor()
        isRegionOverlayClickThrough = false

        processingObserver = nil
        isShowing = false

        NSApp.unhide(nil)

        // Show post-recording dialog after a brief delay to let the app unhide
        if let url = lastURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPostRecordingDialog(for: url)
            }
        }
    }

    // MARK: - Region Mode Coordination

    func showRegionOverlay(on screen: NSScreen, initialRegion: CGRect?) {
        overlayPanel?.close()
        overlayPanel = nil

        let screenFrame = screen.frame
        let scaleFactor = screen.backingScaleFactor

        let panel = CaptureRegionPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Sit above other apps. If a system dialog (e.g. TCC permission prompt) gets stuck behind
        // the overlay, the user can hold CMD or press the click-through toggle on the control
        // panel to make this panel ignore mouse events.
        panel.level = regionOverlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = isRegionOverlayClickThrough || isCmdHeld
        panel.hidesOnDeactivate = false

        let overlayView = CaptureRegionOverlayView(
            screenSize: screenFrame.size,
            displayScaleFactor: scaleFactor,
            initialRegion: initialRegion,
            onRegionChanged: { rect in
                UserDefaults.standard.set(rect.origin.x, forKey: AppConstants.captureRegionXKey)
                UserDefaults.standard.set(rect.origin.y, forKey: AppConstants.captureRegionYKey)
                UserDefaults.standard.set(rect.size.width, forKey: AppConstants.captureRegionWidthKey)
                UserDefaults.standard.set(rect.size.height, forKey: AppConstants.captureRegionHeightKey)
            },
            onCancel: { [weak self] in
                self?.dismissCaptureOverlay()
            }
        )

        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = CGRect(origin: .zero, size: screenFrame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(screenFrame, display: true)

        self.overlayPanel = panel
        panel.makeKeyAndOrderFront(nil)

        // Ensure control panel stays above the overlay
        controlPanel?.level = controlPanelLevelWhenRegionShown
    }

    func hideRegionOverlay() {
        overlayPanel?.close()
        overlayPanel = nil
        // Reset control panel level
        controlPanel?.level = controlPanelLevelWhenAlone
        // The region overlay no longer exists, so the manual click-through toggle has nothing to
        // act on. Reset it so the next time the overlay appears, it starts in the default state.
        isRegionOverlayClickThrough = false
    }

    func moveToDisplay(_ screen: NSScreen, initialRegion: CGRect?) {
        // Recreate overlay on the new screen if in region mode
        let isRegionMode = UserDefaults.standard.bool(forKey: AppConstants.captureRegionModeKey)
        if isRegionMode {
            showRegionOverlay(on: screen, initialRegion: initialRegion)
        }

        // Reposition control panel to the new screen
        if let controlPanel {
            let screenFrame = screen.visibleFrame
            let panelFrame = controlPanel.frame
            let x = screenFrame.midX - panelFrame.width / 2
            let y = screenFrame.minY + 40
            controlPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - Private Methods

    private func createOverlayPanel(on screen: NSScreen) {
        let isRegionMode = UserDefaults.standard.bool(forKey: AppConstants.captureRegionModeKey)
        guard isRegionMode else { return }

        let regionX = UserDefaults.standard.double(forKey: AppConstants.captureRegionXKey)
        let regionY = UserDefaults.standard.double(forKey: AppConstants.captureRegionYKey)
        let regionW = UserDefaults.standard.double(forKey: AppConstants.captureRegionWidthKey)
        let regionH = UserDefaults.standard.double(forKey: AppConstants.captureRegionHeightKey)

        let initialRegion: CGRect?
        if regionW > 0, regionH > 0 {
            initialRegion = CGRect(x: regionX, y: regionY, width: regionW, height: regionH)
        } else {
            initialRegion = nil
        }

        showRegionOverlay(on: screen, initialRegion: initialRegion)
    }

    private func createControlPanel(on screen: NSScreen) {
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 520
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY + 40

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = overlayPanel != nil ? controlPanelLevelWhenRegionShown : controlPanelLevelWhenAlone
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = isCmdHeld
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let controlView = CaptureControlPanelView(
            onCancel: { [weak self] in
                self?.dismissCaptureOverlay()
            },
            onStartRecording: { [weak self] in
                self?.startRecording()
            },
            onStopRecording: { [weak self] in
                self?.stopRecordingAndShowDialog()
            },
            onHidePanel: { [weak self] in
                self?.hideControlPanel()
            },
            onRegionModeChanged: { [weak self] isRegion in
                guard let self else { return }
                if isRegion {
                    guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
                    let regionX = UserDefaults.standard.double(forKey: AppConstants.captureRegionXKey)
                    let regionY = UserDefaults.standard.double(forKey: AppConstants.captureRegionYKey)
                    let regionW = UserDefaults.standard.double(forKey: AppConstants.captureRegionWidthKey)
                    let regionH = UserDefaults.standard.double(forKey: AppConstants.captureRegionHeightKey)
                    let initial: CGRect? = (regionW > 0 && regionH > 0)
                        ? CGRect(x: regionX, y: regionY, width: regionW, height: regionH)
                        : nil
                    self.showRegionOverlay(on: screen, initialRegion: initial)
                } else {
                    self.hideRegionOverlay()
                }
            },
            onDisplayChanged: { [weak self] screen, initialRegion in
                self?.moveToDisplay(screen, initialRegion: initialRegion)
            },
            onSetOverlayClickThrough: { [weak self] enabled in
                self?.setRegionOverlayClickThrough(enabled)
            },
            onScaleChanged: { [weak self] in
                self?.resizeControlPanelToFit()
            }
        )

        let hosting = NSHostingView(rootView: controlView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        self.controlPanel = panel
        self.controlHostingView = hosting

        panel.makeKeyAndOrderFront(nil)
    }

    private func setupRecordingObservers() {
        let captureManager = ScreenCaptureManager.shared

        // Only react when processing finishes — this is the final state after recording stops.
        // isRecording goes false first, then isProcessing goes true (writing file),
        // then isProcessing goes false (file complete, lastOutputURL set).
        processingObserver = captureManager.$isProcessing
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] isProcessing in
                guard let self else { return }
                if !isProcessing && !captureManager.isRecording {
                    self.handleRecordingStopped()
                }
            }
    }

    private func showPostRecordingDialog(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Recording Saved"
        alert.informativeText = url.lastPathComponent
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add to Encoding Queue")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NotificationCenter.default.post(name: .enqueueFileURL, object: url)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    // MARK: - Escape Key Handling

    private func installEscapeKeyMonitor() {
        guard escapeKeyLocalMonitor == nil else { return }

        let handleEscape = { [weak self] in
            guard let self else { return }
            let manager = ScreenCaptureManager.shared
            if !manager.isRecording && !manager.isProcessing {
                self.dismissCaptureOverlay()
            }
        }

        // Local monitor catches Escape when our app/panels are focused
        escapeKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                handleEscape()
                return nil
            }
            return event
        }

        // Global monitor catches Escape when another app is focused
        // (since the overlay panel is non-activating, focus stays with the previous app)
        escapeKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                handleEscape()
            }
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyLocalMonitor = nil
        }
        if let monitor = escapeKeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyGlobalMonitor = nil
        }
    }

    // MARK: - Click-Through

    /// Public toggle used by the floating control panel's button. Affects only the region overlay
    /// so the control panel itself stays clickable for un-toggling.
    func setRegionOverlayClickThrough(_ enabled: Bool) {
        isRegionOverlayClickThrough = enabled
        applyClickThroughState()
    }

    private func applyClickThroughState() {
        overlayPanel?.ignoresMouseEvents = isRegionOverlayClickThrough || isCmdHeld
        // Holding CMD also passes events through the control panel, so a TCC dialog (or any
        // window) hidden behind it can be reached. The manual toggle does not affect the control
        // panel — that would lock the user out of the toggle itself.
        controlPanel?.ignoresMouseEvents = isCmdHeld
    }

    // MARK: - Modifier Key Handling

    private func installModifierKeyMonitor() {
        guard modifierKeyLocalMonitor == nil else { return }

        let handleFlags = { [weak self] (event: NSEvent) in
            guard let self else { return }
            let cmdNow = event.modifierFlags.contains(.command)
            if cmdNow != self.isCmdHeld {
                self.isCmdHeld = cmdNow
                self.applyClickThroughState()
            }
        }

        modifierKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
            return event
        }

        modifierKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
        }
    }

    private func removeModifierKeyMonitor() {
        if let monitor = modifierKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierKeyLocalMonitor = nil
        }
        if let monitor = modifierKeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierKeyGlobalMonitor = nil
        }
        isCmdHeld = false
        applyClickThroughState()
    }

    // MARK: - Menu Bar Status Item

    /// Shows a single red menu-bar icon whose click opens a dropdown with recording controls
    /// (stop, show/hide preview, extend auto-stop) and a read-only status section.
    private func showStatusItems() {
        if showPanelStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                image?.isTemplate = false
                button.image = image
                button.contentTintColor = .systemRed
                button.toolTip = "Screen Recording"
            }
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            showPanelStatusItem = item
        }
        showPanelStatusItem?.isVisible = true
    }

    private func hideStatusItems() {
        statusMenuUpdateTimer?.invalidate()
        statusMenuUpdateTimer = nil
        showPanelStatusItem?.isVisible = false
    }

    /// Rebuilds the status-bar dropdown with the current recording / auto-stop state.
    private func rebuildStatusMenu(_ menu: NSMenu) {
        let manager = ScreenCaptureManager.shared
        menu.removeAllItems()

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(menuStopRecording), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())

        let panelVisible = controlPanel?.isVisible == true
        let toggle = NSMenuItem(
            title: panelVisible ? "Hide Preview" : "Show Preview",
            action: #selector(menuTogglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Extend auto-stop submenu — increments start a fresh auto-stop when none is active.
        let extendItem = NSMenuItem(title: "Extend Auto-Stop", action: nil, keyEquivalent: "")
        let extendMenu = NSMenu()
        for minutes in [1, 5, 10, 30] {
            let entry = NSMenuItem(title: "+\(minutes) min", action: #selector(menuExtendAutoStop(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = NSNumber(value: minutes * 60)
            extendMenu.addItem(entry)
        }
        if manager.autoStopDate != nil {
            extendMenu.addItem(.separator())
            let cancel = NSMenuItem(title: "Cancel Auto-Stop", action: #selector(menuCancelAutoStop), keyEquivalent: "")
            cancel.target = self
            extendMenu.addItem(cancel)
        }
        extendItem.submenu = extendMenu
        menu.addItem(extendItem)

        menu.addItem(.separator())

        let recorded = NSMenuItem(
            title: "Recorded: \(Self.statusDurationFormatter.string(from: manager.elapsedTime) ?? "00:00:00")",
            action: nil,
            keyEquivalent: ""
        )
        recorded.isEnabled = false
        menu.addItem(recorded)

        if let stopDate = manager.autoStopDate {
            let remaining = max(0, stopDate.timeIntervalSinceNow)
            let stopsIn = NSMenuItem(
                title: "Stops in: \(Self.statusDurationFormatter.string(from: remaining) ?? "00:00:00")",
                action: nil,
                keyEquivalent: ""
            )
            stopsIn.isEnabled = false
            menu.addItem(stopsIn)

            let stopsAt = NSMenuItem(
                title: "Auto-stop at: \(Self.statusClockFormatter.string(from: stopDate))",
                action: nil,
                keyEquivalent: ""
            )
            stopsAt.isEnabled = false
            menu.addItem(stopsAt)
        }
    }

    @objc private func menuStopRecording() {
        stopRecordingAndShowDialog()
    }

    @objc private func menuTogglePanel() {
        if controlPanel?.isVisible == true {
            hideControlPanel()
        } else {
            showControlPanel()
        }
    }

    @objc private func menuExtendAutoStop(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        ScreenCaptureManager.shared.extendAutoStop(by: seconds)
    }

    @objc private func menuCancelAutoStop() {
        ScreenCaptureManager.shared.cancelAutoStop()
    }

    private static let statusDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private static let statusClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // Avoid sending the non-Sendable `menu` parameter into the MainActor region; the controller
        // owns the same menu via `showPanelStatusItem`.
        MainActor.assumeIsolated {
            statusMenuTick()
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // Tick the countdown / elapsed time live while the menu stays open. Use a
            // target/selector timer so the repeating block carries no Sendable-capture concerns.
            statusMenuUpdateTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(statusMenuTick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            statusMenuUpdateTimer = timer
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            statusMenuUpdateTimer?.invalidate()
            statusMenuUpdateTimer = nil
        }
    }

    @objc private func statusMenuTick() {
        guard let menu = showPanelStatusItem?.menu else { return }
        rebuildStatusMenu(menu)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        let closedWindow = notification.object as? NSPanel
        Task { @MainActor in
            if let closedWindow, closedWindow === self.controlPanel {
                if !ScreenCaptureManager.shared.isRecording && !ScreenCaptureManager.shared.isProcessing {
                    self.dismissCaptureOverlay()
                }
            }
        }
    }
}

// MARK: - Capture Region Panel

/// `.nonactivatingPanel` keeps the app from foregrounding when the overlay appears, but it also
/// blocks the panel from becoming key — which means keystrokes (Shift/Option/Space modifiers
/// during a drag, Escape, etc.) flow to whichever app was previously active instead of to our
/// local event monitors. Overriding `canBecomeKey` to `true` lets the panel hold keyboard focus
/// while the app itself stays in the background, so local monitors fire and Space can be
/// swallowed before the underlying app sees it.
private final class CaptureRegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
