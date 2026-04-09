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

struct EncodingGroupHeaderView: View {
    @Binding var group: EncodingGroup
    let globalPreset: ExportPreset
    var isSelected: Bool = false
    var onDelete: () -> Void = {}
    var onAddFiles: () -> Void = {}
    var onReset: () -> Void = {}

    private let presetManager = PresetManager.shared

    private var resolvedPreset: ExportPreset {
        group.preset ?? globalPreset
    }

    /// The concat output URL — taken from the first item's outputURL when concat is enabled and done
    private var concatOutputURL: URL? {
        guard group.concatEnabled, group.status == .done,
              let firstItem = group.items.first else { return nil }
        return firstItem.outputURL
    }

    /// Whether the concat output file already exists (for overwrite warning)
    private var concatOutputExists: Bool {
        guard group.concatEnabled, group.status == .waiting,
              let firstItem = group.items.first,
              let outputURL = firstItem.outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 8) {
                // Top row: expand chevron, name, clip count, output icons, action buttons
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            group.isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)

                    TextField("Group name", text: $group.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .lineLimit(1)

                    if group.clipCount > 0 {
                        Text("\(group.clipCount) clip\(group.clipCount == 1 ? "" : "s")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)

                        if !group.formattedTotalDuration.isEmpty {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(group.formattedTotalDuration)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    } else {
                        Text("Empty group")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Output file icons for concat mode
                    if group.concatEnabled {
                        concatOutputIcons
                    }

                    Button {
                        onAddFiles()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add files to group")

                    Button {
                        onReset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset all items in group")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .help("Delete group")
                }

                // Bottom row: preset picker, feature icons
                HStack(spacing: 12) {
                    Picker("Preset", selection: presetBinding) {
                        Text("Global (\(presetManager.displayName(for: globalPreset)))")
                            .tag(nil as ExportPreset?)
                        Divider()
                        ForEach(presetManager.visiblePresets) { preset in
                            Text(presetManager.displayName(for: preset))
                                .tag(Optional(preset))
                        }
                    }
                    .frame(width: 220)

                    Spacer()

                    HStack(spacing: 4) {
                        // Sequential naming toggle
                        Button {
                            group.sequentialNamingEnabled.toggle()
                            applySequentialNaming()
                        } label: {
                            Image(systemName: group.sequentialNamingEnabled ? "number.circle.fill" : "number.circle")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(group.sequentialNamingEnabled ? .blue : .secondary)
                        .help(group.sequentialNamingEnabled ? "Sequential naming enabled — files will be named \(group.name)_001, \(group.name)_002, ..." : "Enable sequential naming using group name")

                        // Concat toggle
                        Button {
                            group.concatEnabled.toggle()
                        } label: {
                            Image(systemName: group.concatEnabled ? "arrow.triangle.merge" : "arrow.triangle.merge")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(group.concatEnabled ? .blue : .secondary)
                        .help(group.concatEnabled ? "Concat enabled — clips will be merged into one file" : "Enable concat to merge clips into one file")

                        // Upload toggle
                        Button {
                            group.uploadEnabled.toggle()
                        } label: {
                            Image(systemName: group.uploadEnabled ? "icloud.and.arrow.up.fill" : "icloud.and.arrow.up")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(group.uploadEnabled ? .blue : .secondary)
                        .disabled(!UploadManager.shared.isConfigured)
                        .help(group.uploadEnabled ? "Upload enabled — files will upload after encoding" : "Enable upload after encoding")

                        // Transcription toggle
                        Button {
                            group.transcriptionEnabled.toggle()
                        } label: {
                            Image(systemName: group.transcriptionEnabled ? "captions.bubble.fill" : "captions.bubble")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(group.transcriptionEnabled ? .green : .secondary)
                        .help(group.transcriptionEnabled ? "Transcription enabled — SRT will be created after encoding" : "Enable transcription for subtitle generation")

                        // Analytics toggle
                        Button {
                            group.analyticsEnabled.toggle()
                        } label: {
                            Image(systemName: group.analyticsEnabled ? "chart.bar.xaxis.ascending" : "chart.bar.xaxis")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(group.analyticsEnabled ? .cyan : .secondary)
                        .help(group.analyticsEnabled ? "Quality analytics enabled — will run after encoding" : "Enable quality analytics after encoding")
                    }
                }
                .font(.callout)

                // Progress bar when converting
                if group.status == .converting {
                    ProgressView(value: group.progress)
                        .progressViewStyle(.linear)
                }

                // Upload progress when any item is uploading
                if uploadSummary.visible {
                    HStack(spacing: 6) {
                        Image(systemName: uploadSummary.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(uploadSummary.color)
                        Text(uploadSummary.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if uploadSummary.showProgress {
                            ProgressView(value: uploadSummary.progress)
                                .progressViewStyle(.linear)
                        }
                    }
                }
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.blue.opacity(0.3), lineWidth: isSelected ? 2 : 0.8)
        )
        .padding(.horizontal, 4)
        .onChange(of: group.name) { _, _ in
            if group.sequentialNamingEnabled {
                applySequentialNaming()
            }
        }
        .onChange(of: group.items.count) { _, _ in
            if group.sequentialNamingEnabled {
                applySequentialNaming()
            }
        }
    }

    private func applySequentialNaming() {
        if group.sequentialNamingEnabled {
            let processedName = FileNameProcessor.processFileName(group.name)
            for i in group.items.indices {
                group.items[i].outputFileNameOverride = String(format: "%@_%03d", processedName, i + 1)
            }
        } else {
            for i in group.items.indices {
                group.items[i].outputFileNameOverride = nil
            }
        }
    }

    @ViewBuilder
    private var concatOutputIcons: some View {
        // Show in Finder + drag icon when concat output is done
        if let outputURL = concatOutputURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .help("Show merged output in Finder")

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundStyle(.blue)
                .help("Drag to share the merged file")
                .onDrag {
                    let provider = NSItemProvider(object: outputURL as NSURL)
                    provider.suggestedName = outputURL.lastPathComponent
                    return provider
                }
        }

        // Overwrite warning when concat output already exists
        if concatOutputExists, let outputURL = group.items.first?.outputURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Output file already exists and will be overwritten. Click to show in Finder.")
        }
    }

    private struct UploadSummary {
        var visible: Bool
        var icon: String
        var color: Color
        var text: String
        var progress: Double
        var showProgress: Bool
    }

    private var uploadSummary: UploadSummary {
        let items = group.items
        let uploadItems = items.filter { $0.uploadEnabled }
        guard !uploadItems.isEmpty else {
            return UploadSummary(visible: false, icon: "", color: .clear, text: "", progress: 0, showProgress: false)
        }

        let uploaded = uploadItems.filter { $0.uploadStatus.isComplete }.count
        let failed = uploadItems.filter { $0.uploadStatus.hasFailed }.count
        let uploading = uploadItems.filter { $0.uploadStatus == .uploading }
        let pending = uploadItems.filter { $0.uploadStatus == .pending }.count
        let total = uploadItems.count

        // All done
        if uploaded == total {
            return UploadSummary(
                visible: true, icon: "checkmark.icloud.fill", color: .green,
                text: "Uploaded \(uploaded)/\(total)", progress: 1, showProgress: false
            )
        }

        // Some failed
        if failed > 0 && uploading.isEmpty && pending == 0 {
            return UploadSummary(
                visible: true, icon: "exclamationmark.icloud.fill", color: .red,
                text: "Upload failed \(failed)/\(total)", progress: 0, showProgress: false
            )
        }

        // Actively uploading
        if let current = uploading.first {
            let completedProgress = Double(uploaded)
            let currentProgress = current.uploadProgress
            let overallProgress = (completedProgress + currentProgress) / Double(total)
            let speedText = current.uploadSpeed.map { " · \($0)" } ?? ""
            return UploadSummary(
                visible: true, icon: "icloud.and.arrow.up", color: .orange,
                text: "Uploading \(uploaded + 1)/\(total)\(speedText)", progress: overallProgress, showProgress: true
            )
        }

        // Pending
        if pending > 0 {
            return UploadSummary(
                visible: true, icon: "clock.arrow.circlepath", color: .orange,
                text: "Upload pending \(uploaded)/\(total)", progress: Double(uploaded) / Double(total), showProgress: true
            )
        }

        return UploadSummary(visible: false, icon: "", color: .clear, text: "", progress: 0, showProgress: false)
    }

    private var presetBinding: Binding<ExportPreset?> {
        Binding(
            get: { group.preset },
            set: { group.preset = $0 }
        )
    }
}
