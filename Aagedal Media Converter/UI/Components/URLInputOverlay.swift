// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Overlay for entering a URL to download via yt-dlp
struct URLInputOverlay: View {
    @Binding var isPresented: Bool
    var onSubmit: (String, Bool) -> Void
    var onSchedule: ((String, Date, Bool) -> Void)?

    @State private var urlText = ""
    @State private var history: [DownloadHistoryEntry] = []
    @State private var isScheduled = false
    @State private var scheduledDate = Self.defaultScheduleDate()
    @FocusState private var isTextFieldFocused: Bool
    @AppStorage(AppConstants.ytdlpLiveFromStartKey) private var downloadLiveFromStart = false

    /// Returns a default schedule date: 2 minutes from now, rounded to the next full minute
    private static func defaultScheduleDate() -> Date {
        let now = Date()
        let calendar = Calendar.current
        // Get the start of the current minute, then add 2 minutes
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let startOfMinute = calendar.date(from: components) ?? now
        return startOfMinute.addingTimeInterval(120) // 2 minutes from start of current minute
    }

    private var minimumScheduleDate: Date {
        // Round up to the next full minute
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let startOfMinute = calendar.date(from: components) ?? now
        return startOfMinute.addingTimeInterval(60) // Next full minute
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Input panel
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("Download from URL")
                        .font(.headline)

                    Spacer()

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                TextField("Paste video URL (YouTube, Vimeo, etc.)...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        submit()
                    }

                // Invalid URL warning
                if !urlText.isEmpty && !DownloadManager.isValidURL(urlText) {
                    HStack {
                        Label("Invalid URL", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                }

                // Schedule toggle with date picker and action button
                if onSchedule != nil {
                    HStack(spacing: 12) {
                        Toggle(isOn: $isScheduled) {
                            Label("Schedule", systemImage: "clock")
                                .font(.subheadline)
                        }
                        .toggleStyle(.checkbox)

                        DatePicker(
                            "",
                            selection: $scheduledDate,
                            in: minimumScheduleDate...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .disabled(!isScheduled)
                        .opacity(isScheduled ? 1.0 : 0.5)

                        Spacer()

                        Button(isScheduled ? "Schedule" : "Download") {
                            submit()
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(urlText.isEmpty || !DownloadManager.isValidURL(urlText))
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        Spacer()
                        Button("Download") {
                            submit()
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(urlText.isEmpty || !DownloadManager.isValidURL(urlText))
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        downloadLiveFromStart.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: downloadLiveFromStart ? "backward.end.fill" : "backward.end")
                                .font(.system(size: 14, weight: .medium))
                            Text("Record from start")
                                .font(.subheadline)
                        }
                        .foregroundColor(downloadLiveFromStart ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(downloadLiveFromStart ? Color.accentColor : Color.gray.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("When enabled, yt-dlp will rewind live streams to the beginning before recording")

                    Spacer()
                }

                // History section
                if !history.isEmpty {
                    Divider()
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text("Recent Downloads")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(history) { entry in
                                    Button {
                                        urlText = entry.url
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.title)
                                                    .font(.callout)
                                                    .lineLimit(1)
                                                    .foregroundStyle(.primary)

                                                Text(entry.url)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Text(entry.downloadedAt, style: .relative)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(.primary.opacity(0.05))
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                }
            }
            .padding(20)
            .frame(width: 540)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
        .onAppear {
            // Load history
            history = DownloadHistoryService.getHistory()

            // Auto-focus the text field
            isTextFieldFocused = true

            // Check clipboard for URL
            if let clipboardString = NSPasteboard.general.string(forType: .string),
               DownloadManager.isValidURL(clipboardString) {
                urlText = clipboardString
            }
        }
    }

    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, DownloadManager.isValidURL(trimmed) else { return }

        if isScheduled, let onSchedule = onSchedule {
            // Round to the start of the minute (remove seconds)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
            let roundedDate = calendar.date(from: components) ?? scheduledDate
            onSchedule(trimmed, roundedDate, downloadLiveFromStart)
        } else {
            onSubmit(trimmed, downloadLiveFromStart)
        }
        isPresented = false
    }
}

#Preview {
    URLInputOverlay(isPresented: .constant(true)) { url, liveFromStart in
        print("Download: \(url), liveFromStart: \(liveFromStart)")
    }
}
