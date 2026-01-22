// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import CoreGraphics

struct CaptureModeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.hevc42210Bit.rawValue
    @AppStorage(AppConstants.captureDisplayIDKey) private var captureDisplayID = 0
    @AppStorage(AppConstants.captureFrameRateKey) private var captureFrameRateRaw = AppConstants.defaultCaptureFrameRate
    @AppStorage(AppConstants.captureDynamicRangeKey) private var captureDynamicRangeRaw = AppConstants.defaultCaptureDynamicRange
    @AppStorage(AppConstants.captureHideCursorKey) private var captureHideCursor = AppConstants.defaultCaptureHideCursor
    @AppStorage(AppConstants.captureExcludeCurrentAppKey) private var captureExcludeCurrentApp = AppConstants.defaultCaptureExcludeCurrentApp
    @StateObject private var captureManager = ScreenCaptureManager.shared
    @State private var availableDisplays: [CaptureDisplay] = []
    @State private var isViewActive = false

    private var presetBinding: Binding<CapturePreset> {
        Binding(
            get: {
                let preset = CapturePreset(rawValue: capturePresetRaw) ?? .hevc42210Bit
                return CapturePreset.availablePresets.contains(preset) ? preset : .hevc42210Bit
            },
            set: { capturePresetRaw = $0.rawValue }
        )
    }

    private var outputDirectoryURL: URL {
        let trimmed = captureDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConstants.defaultCaptureDirectory : URL(fileURLWithPath: trimmed)
    }

    private var frameRateOption: CaptureFrameRateOption {
        CaptureFrameRateOption(rawValue: captureFrameRateRaw) ?? .auto
    }

    private var dynamicRangeOption: CaptureDynamicRangeOption {
        if captureDynamicRangeRaw == "hdrP3LocalDisplay" {
            return .hdrP3CanonicalDisplay
        }
        return CaptureDynamicRangeOption(rawValue: captureDynamicRangeRaw) ?? .sdr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            Divider()
            previewSection
            controlRow
            outputSection
            if let error = captureManager.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
            }
            Spacer(minLength: 0)
            footerNote
        }
        .padding(16)
        .frame(minWidth: 840, minHeight: 520)
        .interactiveDismissDisabled(captureManager.isRecording || captureManager.isProcessing)
        .onAppear {
            isViewActive = true
            if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
                capturePresetRaw = CapturePreset.hevc42210Bit.rawValue
            }
            Task {
                await loadDisplays()
                await refreshPreview()
            }
        }
        .onDisappear {
            isViewActive = false
            Task {
                await captureManager.stopPreview()
            }
        }
        .onChange(of: captureDisplayID) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureHideCursor) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureExcludeCurrentApp) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureFrameRateRaw) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureDynamicRangeRaw) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureManager.isRecording) { _, isRecording in
            guard !isRecording else { return }
            Task {
                await refreshPreview()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Capture Mode")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .help("Close")
            .disabled(captureManager.isRecording || captureManager.isProcessing)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var previewSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.2))
                if let image = captureManager.previewImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.inset.filled")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text(captureManager.isRecording ? "Waiting for frames..." : "Preview should appear shortly")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, minHeight: 315, maxHeight: 315)

            VStack(alignment: .leading, spacing: 8) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: 315)
            }
            .frame(width: 180, alignment: .leading)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button(action: toggleRecording) {
                Label(captureManager.isRecording ? "Stop" : "Record", systemImage: captureManager.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(captureManager.isRecording ? .red : .accentColor)
            .controlSize(.small)
            .disabled(captureManager.isProcessing)

            if captureManager.isRecording {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundColor(.red)
            } else if captureManager.isProcessing {
                Label("Finalizing", systemImage: "hourglass")
                    .foregroundColor(.orange)
            } else {
                Label("Ready", systemImage: "circle.fill")
                    .foregroundColor(.green)
            }

            Text(elapsedText)
                .font(.callout)
                .monospacedDigit()

            if captureManager.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }

            Spacer()

            Picker("Display", selection: $captureDisplayID) {
                Text("Automatic (Main Display)")
                    .tag(0)
                ForEach(availableDisplays) { display in
                    let label = "\(display.name) (\(display.width)x\(display.height))" + (display.isMain ? " • Main" : "")
                    Text(label).tag(Int(display.id))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 260)
            .disabled(captureManager.isRecording || captureManager.isProcessing)
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if let lastURL = captureManager.lastOutputURL {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last Capture")
                    .font(.headline)
                HStack {
                    Text(lastURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Send to Queue") {
                        NotificationCenter.default.post(name: .enqueueFileURL, object: lastURL)
                    }
                    .controlSize(.small)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([lastURL])
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var footerNote: some View {
        Text("Captures the selected display at native resolution with system audio. Preset and output folder are managed in Settings > Screen Capture.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var elapsedText: String {
        Self.durationFormatter.string(from: captureManager.elapsedTime) ?? "00:00:00"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private func toggleRecording() {
        Task {
            if captureManager.isRecording {
                await captureManager.stopRecording()
            } else {
                let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
                await captureManager.startRecording(
                    preset: presetBinding.wrappedValue,
                    outputDirectory: outputDirectoryURL,
                    displayID: displayID,
                    frameRate: frameRateOption,
                    dynamicRange: dynamicRangeOption,
                    hideCursor: captureHideCursor,
                    excludeCurrentApp: captureExcludeCurrentApp
                )
            }
        }
    }

    private func loadDisplays() async {
        do {
            let displays = try await ScreenCaptureManager.availableDisplays()
            await MainActor.run {
                availableDisplays = displays
                if captureDisplayID != 0,
                   !displays.contains(where: { Int($0.id) == captureDisplayID }) {
                    captureDisplayID = 0
                }
            }
        } catch {
            await MainActor.run {
                availableDisplays = []
                captureDisplayID = 0
            }
        }
    }

    private func refreshPreview() async {
        guard isViewActive, !captureManager.isRecording else { return }
        await captureManager.stopPreview()
        let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
        await captureManager.startPreview(
            displayID: displayID,
            frameRate: frameRateOption,
            hideCursor: captureHideCursor,
            excludeCurrentApp: captureExcludeCurrentApp
        )
    }
}

#Preview {
    CaptureModeView()
}
