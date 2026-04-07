// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A scrollable sheet for picking one track from a potentially large list.
/// Used for subtitle track (OCR) and audio track (Whisper) selection.
struct TrackPickerSheet: View {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let action: () -> Void
    }

    let title: String
    let message: String
    let rows: [Row]
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Track list
            List(rows) { row in
                Button(action: row.action) {
                    Text(row.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            .listStyle(.plain)

            Divider()

            // Cancel
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .padding(.vertical, 12)
        }
        .frame(width: 380, height: min(80 + CGFloat(rows.count) * 40, 480))
    }
}
