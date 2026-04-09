// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit

struct CaptureControlPanelView: View {
    let onCancel: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onHidePanel: () -> Void
    let onRegionModeChanged: (Bool) -> Void
    let onDisplayChanged: (NSScreen, CGRect?) -> Void

    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.hevc42210Bit.rawValue
    @AppStorage(AppConstants.captureDisplayIDKey) private var captureDisplayID = 0
    @AppStorage(AppConstants.captureFrameRateKey) private var captureFrameRateRaw = AppConstants.defaultCaptureFrameRate
    @AppStorage(AppConstants.captureDynamicRangeKey) private var captureDynamicRangeRaw = AppConstants.defaultCaptureDynamicRange
    @AppStorage(AppConstants.captureHideCursorKey) private var captureHideCursor = AppConstants.defaultCaptureHideCursor
    @AppStorage(AppConstants.captureExcludeCurrentAppKey) private var captureExcludeCurrentApp = AppConstants.defaultCaptureExcludeCurrentApp
    @AppStorage(AppConstants.captureIncludeSystemAudioKey) private var captureIncludeSystemAudio = AppConstants.defaultCaptureIncludeSystemAudio
    @AppStorage(AppConstants.captureIncludeMicrophoneKey) private var captureIncludeMicrophone = AppConstants.defaultCaptureIncludeMicrophone
    @AppStorage(AppConstants.captureMicrophoneDeviceIDKey) private var captureMicrophoneDeviceID = AppConstants.defaultCaptureMicrophoneDeviceID
    @AppStorage(AppConstants.captureRegionModeKey) private var captureRegionMode = AppConstants.defaultCaptureRegionMode
    @AppStorage(AppConstants.captureRegionXKey) private var captureRegionX: Double = 0
    @AppStorage(AppConstants.captureRegionYKey) private var captureRegionY: Double = 0
    @AppStorage(AppConstants.captureRegionWidthKey) private var captureRegionWidth: Double = 0
    @AppStorage(AppConstants.captureRegionHeightKey) private var captureRegionHeight: Double = 0

    @StateObject private var captureManager = ScreenCaptureManager.shared
    @State private var availableDisplays: [CaptureDisplay] = []
    @State private var microphoneDevices: [AVCaptureDevice] = []
    @State private var isViewActive = false
    @State private var isMicButtonHovering = false
    @State private var showAudioExclusionPopover = false
    @State private var availableApps: [SCRunningApplication] = []
    @State private var excludedAppBundleIDs: Set<String> = []

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

    private var selectedMicrophoneDeviceID: String? {
        captureMicrophoneDeviceID.isEmpty ? nil : captureMicrophoneDeviceID
    }

    private var selectedRegionRect: CGRect? {
        guard captureRegionMode, captureRegionWidth > 0, captureRegionHeight > 0 else { return nil }
        return CGRect(x: captureRegionX, y: captureRegionY, width: captureRegionWidth, height: captureRegionHeight)
    }

    private var microphoneSelectionSupported: Bool {
        if #available(macOS 15, *) {
            return true
        }
        return false
    }

    var body: some View {
        panelContent
            .onAppear { handleOnAppear() }
            .onDisappear { isViewActive = false }
            .modifier(DisplayAndModeModifier(
                captureDisplayID: $captureDisplayID,
                captureRegionMode: $captureRegionMode,
                captureRegionWidth: $captureRegionWidth,
                captureRegionHeight: $captureRegionHeight,
                onRegionModeChanged: onRegionModeChanged,
                notifyDisplayChanged: notifyDisplayChanged,
                refreshPreview: { await self.refreshPreview() }
            ))
            .modifier(PreviewRefreshModifier(
                captureHideCursor: captureHideCursor,
                captureExcludeCurrentApp: captureExcludeCurrentApp,
                captureFrameRateRaw: captureFrameRateRaw,
                captureIncludeMicrophone: captureIncludeMicrophone,
                captureDynamicRangeRaw: captureDynamicRangeRaw,
                excludedAppBundleIDs: excludedAppBundleIDs,
                captureRegionX: captureRegionX,
                captureRegionY: captureRegionY,
                captureRegionWidth: captureRegionWidth,
                captureRegionHeight: captureRegionHeight,
                isRecording: captureManager.isRecording,
                refreshPreview: { await self.refreshPreview() }
            ))
    }

    private var panelContent: some View {
        Group {
            if captureManager.isRecording || captureManager.isProcessing {
                recordingStateView
            } else {
                setupStateView
            }
        }
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12)
    }

    private func handleOnAppear() {
        isViewActive = true
        if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
            capturePresetRaw = CapturePreset.hevc42210Bit.rawValue
        }
        Task {
            async let microphonesTask: () = loadMicrophones()
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                let displays = ScreenCaptureManager.displays(from: content)
                let apps = content.applications
                await MainActor.run {
                    availableDisplays = displays
                    availableApps = apps
                    if captureDisplayID != 0,
                       !displays.contains(where: { Int($0.id) == captureDisplayID }) {
                        captureDisplayID = 0
                    }
                }
                captureManager.refreshMicrophoneAuthorizationStatus()
                await startPreview(with: content)
            } catch {
                await MainActor.run {
                    availableDisplays = []
                    captureDisplayID = 0
                }
            }
            await microphonesTask
        }
    }

    // MARK: - Setup State View

    private var setupStateView: some View {
        VStack(spacing: 0) {
            // Preview
            previewSection
                .padding(12)

            Divider()

            // Controls
            controlsSection
                .padding(12)

            Divider()

            // Bottom bar
            bottomBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 480)
    }

    private var previewSection: some View {
        VStack(spacing: 6) {
            // Sys meter | Preview | Mic meter
            HStack(spacing: 6) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: 190, chrome: false)
                    .opacity(captureIncludeSystemAudio ? 1.0 : 0.3)
                    .frame(width: 12)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                    if let image = captureManager.previewImage {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text("Preview")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 200)

                AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: 190, chrome: false)
                    .saturation(microphoneButtonActive ? 1.0 : 0.0)
                    .opacity(microphoneButtonActive ? 1.0 : 0.3)
                    .frame(width: 12)
            }

            // Speaker toggle | Display picker | Mic toggle
            HStack {
                Button {
                    captureIncludeSystemAudio.toggle()
                } label: {
                    Image(systemName: captureIncludeSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(captureIncludeSystemAudio ? .accentColor : .secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(captureIncludeSystemAudio ? "System audio on" : "System audio off")

                Spacer()

                Picker("Display", selection: $captureDisplayID) {
                    Text("Automatic (Main)")
                        .tag(0)
                    ForEach(availableDisplays) { display in
                        let label = "\(display.name) (\(display.width)x\(display.height))" + (display.isMain ? " - Main" : "")
                        Text(label).tag(Int(display.id))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()

                Spacer()

                Button {
                    let willEnable = !captureIncludeMicrophone
                    captureIncludeMicrophone = willEnable
                    if willEnable {
                        Task { await captureManager.requestMicrophonePermission() }
                    }
                } label: {
                    Image(systemName: captureIncludeMicrophone ? "mic.fill" : "mic.slash")
                        .font(.system(size: 10))
                        .foregroundColor(microphoneButtonActive ? .accentColor : .secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(captureIncludeMicrophone ? "Microphone on" : "Microphone off")
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 10) {
            // Toggle buttons + mode toggle in one row
            HStack(spacing: 8) {
                Picker("Mode", selection: $captureRegionMode) {
                    Text("Full Screen").tag(false)
                    Text("Region").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                cursorToggleButton
                excludeAppToggleButton
                audioExclusionButton
                Spacer()
            }

            // Error message
            if let error = captureManager.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: handleRecord) {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.regular)
        }
    }

    // MARK: - Recording State View

    private var recordingStateView: some View {
        VStack(spacing: 0) {
            // Sys meter | Preview | Mic meter
            HStack(spacing: 6) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: 190, chrome: false)
                    .opacity(captureIncludeSystemAudio ? 1.0 : 0.3)
                    .frame(width: 12)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                    if let image = captureManager.previewImage {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(height: 200)

                AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: 190, chrome: false)
                    .saturation(microphoneButtonActive ? 1.0 : 0.0)
                    .opacity(microphoneButtonActive ? 1.0 : 0.3)
                    .frame(width: 12)
            }
            .padding(12)

            Divider()

            HStack(spacing: 12) {
                // Recording indicator
                if captureManager.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .modifier(PulsingAnimation())
                }

                if captureManager.isProcessing {
                    Label("Finalizing", systemImage: "hourglass")
                        .foregroundColor(.orange)
                        .font(.callout)
                } else {
                    Text(elapsedText)
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                }

                Spacer()

                Button(action: onHidePanel) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Hide this panel (use menu bar icon to re-open)")

                if captureManager.isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Button(action: onStopRecording) {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 480)
    }

    // MARK: - Toggle Buttons

    private var microphoneToggleButton: some View {
        Button {
            let willEnable = !captureIncludeMicrophone
            captureIncludeMicrophone = willEnable
            if willEnable {
                Task {
                    await captureManager.requestMicrophonePermission()
                }
            }
        } label: {
            Image(systemName: captureIncludeMicrophone ? "mic.fill" : "mic.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(microphoneIconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(microphoneButtonBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(microphoneButtonBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isMicButtonHovering = hovering }
        .help(microphoneButtonHelpText)
    }

    private var microphoneIconColor: Color {
        if captureIncludeMicrophone {
            switch captureManager.microphoneCaptureStatus {
            case .authorized: return .white
            case .denied: return .orange
            case .disabled: return .yellow
            }
        }
        return .primary
    }

    private var microphoneButtonBackground: Color {
        if microphoneButtonActive {
            return Color.accentColor.opacity(isMicButtonHovering ? 0.35 : 0.25)
        }
        if captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .denied {
            return Color.red.opacity(isMicButtonHovering ? 0.16 : 0.12)
        }
        return Color.primary.opacity(isMicButtonHovering ? 0.15 : 0.06)
    }

    private var microphoneButtonBorder: Color {
        if microphoneButtonActive {
            return Color.accentColor
        }
        if captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .denied {
            return Color.red
        }
        return Color.primary.opacity(0.35)
    }

    private var microphoneButtonHelpText: String {
        if captureIncludeMicrophone {
            switch captureManager.microphoneCaptureStatus {
            case .authorized:
                return "Microphone will be recorded as a separate 24-bit LPCM track."
            case .denied:
                return "Microphone access is blocked; click to re-open the permission prompt."
            case .disabled:
                return "Requesting microphone permission so a secondary track can be captured."
            }
        }
        return "Enable the microphone track (system + mic) so you can capture narrations."
    }

    private var microphoneButtonActive: Bool {
        captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .authorized
    }

    private var cursorToggleButton: some View {
        Button {
            captureHideCursor.toggle()
        } label: {
            Image(systemName: captureHideCursor ? "cursorarrow.slash" : "cursorarrow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(captureHideCursor ? .secondary : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(captureHideCursor ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(captureHideCursor ? Color.primary.opacity(0.2) : Color.accentColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(captureHideCursor ? "Cursor hidden in capture" : "Cursor visible in capture")
    }

    private var excludeAppToggleButton: some View {
        Button {
            captureExcludeCurrentApp.toggle()
        } label: {
            Image(systemName: captureExcludeCurrentApp ? "macwindow.on.rectangle" : "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(captureExcludeCurrentApp ? .secondary : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(captureExcludeCurrentApp ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(captureExcludeCurrentApp ? Color.primary.opacity(0.2) : Color.accentColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(captureExcludeCurrentApp ? "This app excluded from capture" : "This app visible in capture")
    }

    private var audioExclusionButton: some View {
        Button {
            showAudioExclusionPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: excludedAppBundleIDs.isEmpty ? "eye" : "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(excludedAppBundleIDs.isEmpty ? .secondary : .orange)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(excludedAppBundleIDs.isEmpty ? Color.primary.opacity(0.06) : Color.orange.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(excludedAppBundleIDs.isEmpty ? Color.primary.opacity(0.2) : Color.orange.opacity(0.6), lineWidth: 1)
                    )
                if !excludedAppBundleIDs.isEmpty {
                    Text("\(excludedAppBundleIDs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help(excludedAppBundleIDs.isEmpty ? "Hide and exclude sound from apps" : "\(excludedAppBundleIDs.count) app(s) hidden")
        .popover(isPresented: $showAudioExclusionPopover, arrowEdge: .bottom) {
            audioExclusionPopoverContent
        }
    }

    private var audioExclusionPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hide and Exclude Sound")
                .font(.headline)
                .padding(.bottom, 4)

            if availableApps.isEmpty {
                Text("No apps available")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableApps.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted(by: { $0.applicationName < $1.applicationName }), id: \.bundleIdentifier) { app in
                            let bundleID = app.bundleIdentifier
                            Button {
                                if excludedAppBundleIDs.contains(bundleID) {
                                    excludedAppBundleIDs.remove(bundleID)
                                } else {
                                    excludedAppBundleIDs.insert(bundleID)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: excludedAppBundleIDs.contains(bundleID) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(excludedAppBundleIDs.contains(bundleID) ? .accentColor : .secondary)
                                    Text(app.applicationName)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if !excludedAppBundleIDs.isEmpty {
                Divider()
                Button("Clear All") {
                    excludedAppBundleIDs.removeAll()
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    // MARK: - Helpers

    private var elapsedText: String {
        Self.durationFormatter.string(from: captureManager.elapsedTime) ?? "00:00:00"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private func handleRecord() {
        Task {
            let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
            onStartRecording()
            await captureManager.startRecording(
                preset: presetBinding.wrappedValue,
                outputDirectory: outputDirectoryURL,
                displayID: displayID,
                frameRate: frameRateOption,
                dynamicRange: dynamicRangeOption,
                includeSystemAudio: captureIncludeSystemAudio,
                includeMicrophone: captureIncludeMicrophone,
                microphoneDeviceID: selectedMicrophoneDeviceID,
                hideCursor: captureHideCursor,
                excludeCurrentApp: captureExcludeCurrentApp,
                excludedAppBundleIDs: excludedAppBundleIDs,
                regionRect: selectedRegionRect
            )
        }
    }

    private func refreshPreview() async {
        await startPreview(with: nil)
    }

    private func startPreview(with cachedContent: SCShareableContent?) async {
        guard isViewActive, !captureManager.isRecording else { return }
        await captureManager.stopPreview()
        let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
        await captureManager.startPreview(
            displayID: displayID,
            frameRate: frameRateOption,
            includeMicrophone: captureIncludeMicrophone,
            microphoneDeviceID: selectedMicrophoneDeviceID,
            hideCursor: captureHideCursor,
            excludeCurrentApp: captureExcludeCurrentApp,
            excludedAppBundleIDs: excludedAppBundleIDs,
            cachedContent: cachedContent,
            regionRect: selectedRegionRect
        )
    }

    private func loadMicrophones() async {
        guard #available(macOS 15, *) else {
            await MainActor.run {
                microphoneDevices = []
                captureMicrophoneDeviceID = ""
            }
            return
        }
        let devices = ScreenCaptureManager.availableMicrophones()
        await MainActor.run {
            microphoneDevices = devices
            if !devices.contains(where: { $0.uniqueID == captureMicrophoneDeviceID }) {
                captureMicrophoneDeviceID = ""
            }
        }
    }

    private func notifyDisplayChanged() {
        let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
        let screen: NSScreen
        if let displayID, let s = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            screen = s
        } else {
            screen = NSScreen.main ?? NSScreen.screens[0]
        }
        onDisplayChanged(screen, selectedRegionRect)
    }
}

// MARK: - Visual Effect Blur

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Pulsing Animation

private struct PulsingAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Display and Mode Modifier

private struct DisplayAndModeModifier: ViewModifier {
    @Binding var captureDisplayID: Int
    @Binding var captureRegionMode: Bool
    @Binding var captureRegionWidth: Double
    @Binding var captureRegionHeight: Double
    let onRegionModeChanged: (Bool) -> Void
    let notifyDisplayChanged: () -> Void
    let refreshPreview: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: captureDisplayID) { _, _ in
                if captureRegionMode {
                    captureRegionWidth = 0
                    captureRegionHeight = 0
                }
                notifyDisplayChanged()
                Task { await refreshPreview() }
            }
            .onChange(of: captureRegionMode) { _, newValue in
                onRegionModeChanged(newValue)
                Task { await refreshPreview() }
            }
    }
}

// MARK: - Preview Refresh Modifier

private struct PreviewRefreshModifier: ViewModifier {
    let captureHideCursor: Bool
    let captureExcludeCurrentApp: Bool
    let captureFrameRateRaw: String
    let captureIncludeMicrophone: Bool
    let captureDynamicRangeRaw: String
    let excludedAppBundleIDs: Set<String>
    let captureRegionX: Double
    let captureRegionY: Double
    let captureRegionWidth: Double
    let captureRegionHeight: Double
    let isRecording: Bool
    let refreshPreview: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: captureHideCursor) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureExcludeCurrentApp) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureFrameRateRaw) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureIncludeMicrophone) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureDynamicRangeRaw) { _, _ in Task { await refreshPreview() } }
            .onChange(of: excludedAppBundleIDs) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionX) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionY) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionWidth) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionHeight) { _, _ in Task { await refreshPreview() } }
            .onChange(of: isRecording) { _, newValue in
                guard !newValue else { return }
                Task { await refreshPreview() }
            }
    }
}
