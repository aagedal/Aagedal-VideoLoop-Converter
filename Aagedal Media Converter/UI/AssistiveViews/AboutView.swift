// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

struct AboutView: View {
    private let homepageURL = URL(string: "https://mediaconverter.aagedal.me")!
    private let repoURL = URL(string: "https://codeberg.org/taagedal/Aagedal-Media-Converter")!

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .cornerRadius(20)
            }
            VStack(spacing: 4) {
                Text("Aagedal Media Converter")
                    .font(.title)
                    .fontWeight(.semibold)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Text("Minimalist FFMPEG frontend written in Swift and SwiftUI.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("FFMPEG version: 8.1")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Link("Homepage", destination: homepageURL)
                Link("GitHub Repository", destination: repoURL)
            }
            .font(.subheadline)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                Text("Aagedal Media Converter is licensed under GPL-3.0-or-later.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("Bundles FFmpeg, mpv, tesseract, asdcplib and bmx; optionally downloads yt-dlp, Deno, rclone, whisper.cpp and Parakeet at runtime. Each component is distributed under its own license — see the Licenses folder in the source repository for bundled components' full terms.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)
        }
        .padding(24)
        .frame(width: 440)
    }
}

#Preview {
    AboutView()
}
