// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit

// Workaround for MoltenVK problems - matches MPVKit demo
// https://github.com/mpv-player/mpv/pull/13651
class MPVMetalLayer: CAMetalLayer {

    override init() {
        super.init()
        configureForHDR()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        configureForHDR()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureForHDR()
    }

    private func configureForHDR() {
        // Enable Extended Dynamic Range (EDR) for HDR content on macOS
        // This allows HDR content to display correctly on HDR-capable displays
        wantsExtendedDynamicRangeContent = true

        // Note: We intentionally don't change pixelFormat or colorspace here
        // because MoltenVK/Vulkan manages these when creating the swapchain.
        // Changing them can cause render target size mismatches during resize.
        // The target-colorspace-hint=yes option in MPVPlayer handles HDR passthrough.
    }

    // Workaround for a MoltenVK that sets the drawableSize to 1x1 to forcefully complete
    // the presentation, this causes flicker and the drawableSize possibly staying at 1x1
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
