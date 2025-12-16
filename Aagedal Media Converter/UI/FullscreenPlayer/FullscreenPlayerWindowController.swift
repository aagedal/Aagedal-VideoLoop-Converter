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
    
    private init() {}
    
    /// Opens a fullscreen player for the given video item
    func openFullscreenPlayer(for item: VideoItem, on screen: NSScreen? = nil) {
        // Close any existing fullscreen player
        dismissWindow()
        
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        
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
        
        // Create the SwiftUI view
        let playerView = FullscreenPlayerView(item: item) { [weak self] in
            self?.closeFullscreenPlayer()
        }
        
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
