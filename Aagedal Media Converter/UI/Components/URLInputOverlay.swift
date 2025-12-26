// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Overlay for entering a URL to download via yt-dlp
struct URLInputOverlay: View {
    @Binding var isPresented: Bool
    var onSubmit: (String) -> Void
    var onSchedule: ((String, Date) -> Void)?

    @State private var urlText = ""
    @State private var showHistory = false
    @State private var history: [DownloadHistoryEntry] = []
    @State private var isScheduled = false
    @State private var scheduledDate = Self.defaultScheduleDate()
    @FocusState private var isTextFieldFocused: Bool

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

                // Schedule toggle
                if onSchedule != nil {
                    HStack {
                        Toggle(isOn: $isScheduled) {
                            Label("Schedule for later", systemImage: "clock")
                                .font(.subheadline)
                        }
                        .toggleStyle(.checkbox)

                        Spacer()

                        if isScheduled {
                            DatePicker(
                                "",
                                selection: $scheduledDate,
                                in: minimumScheduleDate...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .frame(minWidth: 200)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    if !urlText.isEmpty && !DownloadManager.isValidURL(urlText) {
                        Label("Invalid URL", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(isScheduled ? "Schedule" : "Download") {
                        submit()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(urlText.isEmpty || !DownloadManager.isValidURL(urlText))
                    .buttonStyle(.borderedProminent)
                }

                // History section
                if !history.isEmpty {
                    Divider()
                        .padding(.top, 8)

                    DisclosureGroup(isExpanded: $showHistory) {
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
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text("Recent Downloads")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 500)
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
            onSchedule(trimmed, roundedDate)
        } else {
            onSubmit(trimmed)
        }
        isPresented = false
    }
}

#Preview {
    URLInputOverlay(isPresented: .constant(true)) { url in
        print("Download: \(url)")
    }
}
