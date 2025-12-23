// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Manages fullscreen player windows for video playback
@MainActor
final class FullscreenPlayerWindowController {

    static let shared = FullscreenPlayerWindowController()

    private var currentWindow: NSWindow?
    private var hostingView: NSHostingView<FullscreenPlayerView>?

    private var exitFullscreenObserver: Any?
    private var shouldCloseAfterExitFullscreen = false

    // Queue navigation state
    private var queue: [VideoItem] = []
    private var currentIndex: Int = 0
    private var currentScreen: NSScreen?

    // Overlay state preserved across video switches
    private var isOverlayHidden = false

    // Timecode display mode preserved across video switches
    private var currentTimecodeDisplayMode: TimecodeDisplayMode = .preferred

    // Callback to notify when fullscreen player closes with final position
    private var onCloseWithPosition: ((Double) -> Void)?

    // Reference to current player view to get final position
    private var currentPlayerView: FullscreenPlayerView?

    private init() {}
    
    /// Opens a fullscreen player for the given video item
    func openFullscreenPlayer(for item: VideoItem, on screen: NSScreen? = nil) {
        // Close any existing fullscreen player
        dismissWindow()

        // Clear queue if opening without queue context
        if queue.isEmpty || queue.first(where: { $0.id == item.id }) == nil {
            queue = []
            currentIndex = 0
        }

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        currentScreen = targetScreen

        // Create a borderless fullscreen window
        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )

        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Reset state when opening fresh
        isOverlayHidden = false
        currentTimecodeDisplayMode = .preferred

        // Create the SwiftUI view with navigation callbacks
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: false,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onPreviousItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToPreviousItem() }
            },
            onNextItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToNextItem() }
            },
            onOverlayVisibilityChanged: { [weak self] isHidden in
                MainActor.assumeIsolated { self?.isOverlayHidden = isHidden }
            },
            onTimecodeDisplayModeChanged: { [weak self] mode in
                MainActor.assumeIsolated { self?.currentTimecodeDisplayMode = mode }
            },
            canGoToPrevious: canGoToPrevious,
            canGoToNext: canGoToNext
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? targetScreen.frame
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        // Store references
        self.currentWindow = window
        self.hostingView = hostingView

        shouldCloseAfterExitFullscreen = false
        exitFullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.shouldCloseAfterExitFullscreen else { return }
                self.dismissWindow()
            }
        }

        // Enter fullscreen mode
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
    
    /// Opens fullscreen player from the primary screen
    func openFullscreenPlayer(for item: VideoItem) {
        openFullscreenPlayer(for: item, on: nil)
    }

    /// Opens fullscreen player with queue navigation support
    func openFullscreenPlayer(for item: VideoItem, in queue: [VideoItem], on screen: NSScreen? = nil) {
        self.queue = queue
        self.currentIndex = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        openFullscreenPlayer(for: item, on: screen)
    }

    /// Opens fullscreen player from trim view with position synchronization
    /// - Parameters:
    ///   - item: The video item to play
    ///   - startTime: The starting playback position
    ///   - onCloseWithPosition: Callback invoked when player closes with final position
    func openFullscreenPlayerFromTrimView(
        for item: VideoItem,
        startTime: Double,
        onCloseWithPosition: @escaping (Double) -> Void
    ) {
        // Store the callback
        self.onCloseWithPosition = onCloseWithPosition

        // Close any existing fullscreen player
        dismissWindow()

        // Clear queue since we're opening from trim view (single item context)
        queue = []
        currentIndex = 0

        let targetScreen = NSScreen.main ?? NSScreen.screens.first!
        currentScreen = targetScreen

        // Create a borderless fullscreen window
        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )

        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Reset state when opening fresh
        isOverlayHidden = false
        currentTimecodeDisplayMode = .preferred

        // Create the SwiftUI view with position callbacks
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: false,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            startTime: startTime,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onCloseWithPosition: { [weak self] position in
                self?.onCloseWithPosition?(position)
            },
            onPreviousItem: nil,
            onNextItem: nil,
            onOverlayVisibilityChanged: { [weak self] isHidden in
                MainActor.assumeIsolated { self?.isOverlayHidden = isHidden }
            },
            onTimecodeDisplayModeChanged: { [weak self] mode in
                MainActor.assumeIsolated { self?.currentTimecodeDisplayMode = mode }
            },
            canGoToPrevious: false,
            canGoToNext: false
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? targetScreen.frame
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView

        // Store references
        self.currentWindow = window
        self.hostingView = hostingView

        shouldCloseAfterExitFullscreen = false
        exitFullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.shouldCloseAfterExitFullscreen else { return }
                self.dismissWindow()
            }
        }

        // Enter fullscreen mode
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Navigate to the previous item in the queue
    func goToPreviousItem() {
        guard !queue.isEmpty else { return }
        let newIndex = currentIndex - 1
        guard newIndex >= 0 else { return }

        currentIndex = newIndex
        let item = queue[newIndex]
        reopenWithItem(item)
    }

    /// Navigate to the next item in the queue
    func goToNextItem() {
        guard !queue.isEmpty else { return }
        let newIndex = currentIndex + 1
        guard newIndex < queue.count else { return }

        currentIndex = newIndex
        let item = queue[newIndex]
        reopenWithItem(item)
    }

    /// Returns true if navigation to the previous item is possible
    var canGoToPrevious: Bool {
        !queue.isEmpty && currentIndex > 0
    }

    /// Returns true if navigation to the next item is possible
    var canGoToNext: Bool {
        !queue.isEmpty && currentIndex < queue.count - 1
    }

    private func reopenWithItem(_ item: VideoItem) {
        guard let window = currentWindow else { return }

        // Create new player view with updated item, preserving overlay and timecode state
        let playerView = FullscreenPlayerView(
            item: item,
            initialOverlayHidden: isOverlayHidden,
            initialTimecodeDisplayMode: currentTimecodeDisplayMode,
            onClose: { [weak self] in
                self?.closeFullscreenPlayer()
            },
            onPreviousItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToPreviousItem() }
            },
            onNextItem: { [weak self] in
                MainActor.assumeIsolated { self?.goToNextItem() }
            },
            onOverlayVisibilityChanged: { [weak self] isHidden in
                MainActor.assumeIsolated { self?.isOverlayHidden = isHidden }
            },
            onTimecodeDisplayModeChanged: { [weak self] mode in
                MainActor.assumeIsolated { self?.currentTimecodeDisplayMode = mode }
            },
            canGoToPrevious: canGoToPrevious,
            canGoToNext: canGoToNext
        )

        let hostingView = NSHostingView(rootView: playerView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView
        self.hostingView = hostingView
    }
    
    /// Closes the current fullscreen player window
    func closeFullscreenPlayer() {
        guard let window = currentWindow else { return }
        
        if window.styleMask.contains(.fullScreen) {
            shouldCloseAfterExitFullscreen = true
            window.toggleFullScreen(nil)
        } else {
            dismissWindow()
        }
    }
    
    private func dismissWindow() {
        if let observer = exitFullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
            exitFullscreenObserver = nil
        }
        shouldCloseAfterExitFullscreen = false

        currentWindow?.close()
        currentWindow = nil
        hostingView = nil

        // Clear the position callback after window is dismissed
        onCloseWithPosition = nil
    }
    
    /// Returns true if a fullscreen player is currently open
    var isFullscreenPlayerOpen: Bool {
        currentWindow != nil
    }
}

// MARK: - Convenience Extension for VideoItem

extension VideoItem {
    /// Opens this video in the fullscreen player
    @MainActor
    func openInFullscreenPlayer() {
        FullscreenPlayerWindowController.shared.openFullscreenPlayer(for: self)
    }
}
