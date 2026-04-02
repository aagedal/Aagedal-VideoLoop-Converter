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

                // Bottom row: preset picker, toggles
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

                    Toggle("Concat", isOn: $group.concatEnabled)
                        .toggleStyle(.checkbox)

                    Toggle("Upload", isOn: $group.uploadEnabled)
                        .toggleStyle(.checkbox)

                    Toggle("Transcribe", isOn: $group.transcriptionEnabled)
                        .toggleStyle(.checkbox)
                }
                .font(.callout)

                // Progress bar when converting
                if group.status == .converting {
                    ProgressView(value: group.progress)
                        .progressViewStyle(.linear)
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

    private var presetBinding: Binding<ExportPreset?> {
        Binding(
            get: { group.preset },
            set: { group.preset = $0 }
        )
    }
}
