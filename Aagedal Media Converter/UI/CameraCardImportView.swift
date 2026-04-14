// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// A unified entry representing an upload server from any backend type.
struct UploadServerEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
    let backendType: UploadBackendType

    var displayLabel: String {
        "\(name) (\(backendType.displayName))"
    }
}

struct CameraCardImportView: View {
    @Environment(\.openSettings) private var openSettings
    let clipCount: Int
    let folderName: String
    @Binding var masterName: String
    @Binding var selectedPreset: ExportPreset
    @Binding var concatEnabled: Bool
    @Binding var uploadEnabled: Bool
    let mergeCompatibilityResult: ConversionManager.MergeCompatibilityResult?
    let isCheckingCompatibility: Bool
    let onImport: () -> Void
    let onCancel: () -> Void
    let onAutoSplit: (() -> Void)?
    let onForceMerge: (() -> Void)?

    private let presetManager = PresetManager.shared
    @State private var servers: [UploadServerEntry] = []
    @State private var selectedServerID: UUID?

    private var isVideoLoopPreset: Bool {
        selectedPreset == .videoLoop || selectedPreset == .videoLoopWithSound
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Camera Card")
                .font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folderName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(clipCount) clip\(clipCount == 1 ? "" : "s") found")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Card name")
                    .font(.body)
                TextField("e.g. Interview_Day1", text: $masterName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 460)
            }

            if !masterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(namingPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("Preset") {
                Picker("", selection: $selectedPreset) {
                    ForEach(presetManager.visiblePresets) { preset in
                        Text(presetManager.displayName(for: preset)).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            if isVideoLoopPreset {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("VideoLoop is not recommended for card ingest.")
                        .font(.callout)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Use TV AVC-Intra") { selectedPreset = .tvAVCIntra }
                        .controlSize(.small)
                    Button("Use ProRes") { selectedPreset = .prores }
                        .controlSize(.small)
                }
            }

            Divider()

            Toggle("Concatenate clips into single file", isOn: $concatEnabled)

            if concatEnabled {
                if isCheckingCompatibility {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking clip compatibility\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = mergeCompatibilityResult {
                    if case .compatible = result {
                        // Compatible — no warning needed
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(result.tooltip)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let onAutoSplit {
                                Button("Auto-split into groups") {
                                    onAutoSplit()
                                }
                                .controlSize(.small)
                                .help("Create separate encoding groups for compatible clips")
                            }
                            if let onForceMerge {
                                Button("Force Merge\u{2026}") {
                                    onForceMerge()
                                }
                                .controlSize(.small)
                                .help("Re-encode incompatible clips to match a reference, then merge all")
                            }
                        }
                    }
                }
            }

            Toggle("Upload after conversion", isOn: $uploadEnabled)

            if uploadEnabled {
                serverPickerSection
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    applySelectedServer()
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { loadServers() }
    }

    @ViewBuilder
    private var serverPickerSection: some View {
        if servers.isEmpty {
            HStack {
                Text("No upload servers configured")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                addServerButton
            }
        } else if servers.count == 1 {
            HStack {
                Label(servers[0].displayLabel, systemImage: servers[0].backendType.iconName)
                    .font(.callout)
                Spacer()
                addServerButton
            }
        } else {
            HStack {
                Picker("Server", selection: $selectedServerID) {
                    ForEach(servers) { server in
                        Text(server.displayLabel).tag(Optional(server.id))
                    }
                }
                addServerButton
            }
        }
    }

    private var addServerButton: some View {
        Button {
            UserDefaults.standard.set("upload", forKey: AppConstants.settingsTabToOpenKey)
            openSettings()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add server in Upload settings")
    }

    private var namingPreview: String {
        let name = masterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = selectedPreset.fileExtension
        if concatEnabled {
            return "Output: \(name).\(ext)"
        } else if clipCount > 1 {
            return "Output: \(name)_001.\(ext), \(name)_002.\(ext), \u{2026}"
        } else {
            return "Output: \(name)_001.\(ext)"
        }
    }

    private func loadServers() {
        var entries: [UploadServerEntry] = []

        for profile in FTPUploadProfileStore.loadProfiles() where !profile.server.isEmpty {
            entries.append(UploadServerEntry(id: profile.id, name: profile.name, backendType: .ftp))
        }
        for profile in SFTPUploadProfileStore.loadProfiles() where !profile.server.isEmpty {
            entries.append(UploadServerEntry(id: profile.id, name: profile.name, backendType: .sftp))
        }
        for profile in SMBUploadProfileStore.loadProfiles() where !profile.server.isEmpty {
            entries.append(UploadServerEntry(id: profile.id, name: profile.name, backendType: .smb))
        }
        for profile in S3UploadProfileStore.loadProfiles() where !profile.bucket.isEmpty {
            entries.append(UploadServerEntry(id: profile.id, name: profile.name, backendType: .s3))
        }

        servers = entries

        // Pre-select the currently active server
        let activeBackendRaw = UserDefaults.standard.string(forKey: AppConstants.uploadBackendTypeKey) ?? "ftp"
        let activeBackend = UploadBackendType(rawValue: activeBackendRaw) ?? .ftp
        let activeProfileID: UUID? = {
            switch activeBackend {
            case .ftp: return FTPUploadProfileStore.loadSelectedProfileID()
            case .sftp: return SFTPUploadProfileStore.loadSelectedProfileID()
            case .smb: return SMBUploadProfileStore.loadSelectedProfileID()
            case .s3: return S3UploadProfileStore.loadSelectedProfileID()
            case .gdrive: return nil
            }
        }()

        if let activeProfileID, entries.contains(where: { $0.id == activeProfileID }) {
            selectedServerID = activeProfileID
        } else {
            selectedServerID = entries.first?.id
        }
    }

    private func applySelectedServer() {
        guard uploadEnabled,
              let selectedID = selectedServerID ?? servers.first?.id,
              let server = servers.first(where: { $0.id == selectedID }) else { return }

        UserDefaults.standard.set(server.backendType.rawValue, forKey: AppConstants.uploadBackendTypeKey)

        switch server.backendType {
        case .ftp: FTPUploadProfileStore.saveSelectedProfileID(server.id)
        case .sftp: SFTPUploadProfileStore.saveSelectedProfileID(server.id)
        case .smb: SMBUploadProfileStore.saveSelectedProfileID(server.id)
        case .s3: S3UploadProfileStore.saveSelectedProfileID(server.id)
        case .gdrive: break
        }
    }
}
