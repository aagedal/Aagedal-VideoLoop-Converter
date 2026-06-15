// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AppIntents
import UniformTypeIdentifiers
import Foundation

// Notification carrying file URL and output folder URL
extension Notification.Name {
    static let convertImmediately = Notification.Name("convertImmediately")
}

struct ConvertImmediatelyIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Videos Immediately"
    static let description = IntentDescription("Add the selected video files to the queue, set the output folder to the same directory, and start conversion.")

    /// Launch the app if it isn't already running so the conversion still happens.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) immediately")
    }

    func perform() async throws -> some IntentResult {
        let urls = videos.compactMap { $0.fileURL }
        guard let firstURL = urls.first else {
            throw NSError(domain: "ConvertImmediatelyIntent", code: -1, userInfo: [NSLocalizedDescriptionKey: "No valid file URLs"])
        }

        // Use the folder of the first file as the output folder. The request is
        // buffered so it survives the app launching from a closed state (the
        // window's notification receivers may not be ready yet at launch).
        let folder = firstURL.deletingLastPathComponent()
        let requestID = UUID()
        await MainActor.run {
            PendingAppIntentRequests.shared.submit(
                name: .convertImmediately,
                object: nil,
                userInfo: [
                    "fileURLs": urls,
                    "outputFolderURL": folder,
                    PendingAppIntentRequests.requestIDKey: requestID
                ]
            )
        }
        return .result()
    }
}
