// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The SwiftUI `VideoFileRowView` that previously lived here was replaced by
// the AppKit-based `VideoFileCellView` for performance. Only the thumbnail
// caching/decoding utilities remain, since they are consumed by the live
// queue table. Consider renaming this file to `ThumbnailCache.swift` when
// the Xcode project is next edited.

import AppKit
import ImageIO

/// Shared cache for decoded thumbnail images, keyed by VideoItem ID.
/// Eliminates flicker when cells scroll off-screen and back — the decoded
/// NSImage is available immediately instead of re-decoding from Data.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSUUID, NSImage>()

    private init() {
        cache.countLimit = 1000
    }

    subscript(id: UUID) -> NSImage? {
        get { cache.object(forKey: id as NSUUID) }
        set {
            if let image = newValue {
                cache.setObject(image, forKey: id as NSUUID)
            } else {
                cache.removeObject(forKey: id as NSUUID)
            }
        }
    }
}

/// Decodes JPEG thumbnail data off the main thread.
/// Callers receive the decoded image via a completion closure dispatched back to MainActor.
enum ThumbnailDecoder {
    static let queue = DispatchQueue(
        label: "com.aagedal.thumbnaildecoder",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Synchronous decode. Safe to call off-main.
    static func decodeSync(data: Data) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
