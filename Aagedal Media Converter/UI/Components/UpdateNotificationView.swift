// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct UpdateNotificationView: View {
    let latestVersion: String
    let onReleaseNotes: () -> Void
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("New Version Available")
                    .font(.headline)
                Text("Version \(latestVersion) is ready to download.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Release Notes") {
                onReleaseNotes()
            }
            .buttonStyle(.bordered)

            Button("Download") {
                onDownload()
            }
            .buttonStyle(.borderedProminent)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct UpdateNotificationView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.opacity(0.2)
            UpdateNotificationView(
                latestVersion: "1.2.3",
                onReleaseNotes: {},
                onDownload: {},
                onDismiss: {}
            )
        }
        .frame(width: 400, height: 100)
        .padding()
    }
}
