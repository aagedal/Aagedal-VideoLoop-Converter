// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureOverlayWindowController: NSObject, NSWindowDelegate {

    static let shared = CaptureOverlayWindowController()

    private var overlayPanel: NSPanel?
    private var controlPanel: NSPanel?
    private var controlHostingView: NSHostingView<CaptureControlPanelView>?
    private var processingObserver: AnyCancellable?
    private var escapeKeyLocalMonitor: Any?
    private var escapeKeyGlobalMonitor: Any?
    private var modifierKeyLocalMonitor: Any?
    private var modifierKeyGlobalMonitor: Any?

    // Menu bar status item for showing/hiding the control panel
    private var showPanelStatusItem: NSStatusItem?

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

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens[0]

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

        let panel = NSPanel(
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
                let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
                if isRegion {
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

    // MARK: - Menu Bar Status Items

    private func showStatusItems() {
        if showPanelStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Show Capture Panel")
                image?.isTemplate = true
                button.image = image
                button.target = self
                button.action = #selector(statusBarTogglePanel)
                button.toolTip = "Show Capture Controls"
            }
            showPanelStatusItem = item
        }
        showPanelStatusItem?.isVisible = true
    }

    private func hideStatusItems() {
        showPanelStatusItem?.isVisible = false
    }

    @objc private func statusBarTogglePanel() {
        if controlPanel?.isVisible == true {
            hideControlPanel()
        } else {
            showControlPanel()
        }
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
