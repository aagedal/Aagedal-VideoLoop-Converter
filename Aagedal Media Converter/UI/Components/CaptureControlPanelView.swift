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
    let onSetOverlayClickThrough: (Bool) -> Void
    let onScaleChanged: () -> Void

    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.defaultPreset.rawValue
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
    @AppStorage("screenRecordingAspectRatio") private var lockedAspectRatioRaw: String = AspectRatio.free.rawValue
    @AppStorage(AppConstants.captureOverlayExpandedKey) private var isExpanded = false

    @StateObject private var captureManager = ScreenCaptureManager.shared
    @State private var availableDisplays: [CaptureDisplay] = []
    @State private var microphoneDevices: [AVCaptureDevice] = []
    @State private var isViewActive = false
    @State private var isMicButtonHovering = false
    @State private var showAudioExclusionPopover = false
    @State private var availableApps: [SCRunningApplication] = []
    @State private var excludedAppBundleIDs: Set<String> = []
    @State private var overlayClickThrough = false

    // Schedule state
    @State private var showSchedulePopover = false
    @State private var scheduleStartDate = Date().addingTimeInterval(300)
    @State private var scheduleUseDuration = false
    @State private var scheduleDurationHours = 0
    @State private var scheduleDurationMinutes = 5
    @State private var scheduledStart: Date?
    @State private var scheduledDuration: TimeInterval?
    @State private var scheduleCountdown: TimeInterval = 0
    @State private var schedulePowerAssertion: UUID?

    private var presetBinding: Binding<CapturePreset> {
        Binding(
            get: {
                let preset = CapturePreset(rawValue: capturePresetRaw) ?? .defaultPreset
                return CapturePreset.availablePresets.contains(preset) ? preset : .defaultPreset
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

    // MARK: - Overlay Sizing
    //
    // Two discrete states instead of a free-form drag: compact (default) and expanded.
    // Expanded sizes the preview to the captured area's aspect ratio, as large as fits within
    // ~90% of the screen, so it fills edge-to-edge with no letterboxing. The audio meters keep
    // their fixed 12pt width in both states — only their height and the video preview grow.
    // The panel sizes itself to the SwiftUI content via the controller's fitting-size resize;
    // the horizontal chrome below must match the meter columns + spacing + padding in the layout.
    private static let baseContentWidth: CGFloat = 480           // minimum panel width (keeps controls usable)
    private static let horizontalChrome: CGFloat = 60            // 2×(meter 12 + spacing 6 + outer padding 12)
    private static let compactPreviewBounds = CGSize(width: 420, height: 240)
    private static let expandedScreenFraction: CGFloat = 0.9
    /// Reserved vertical space for everything that isn't the preview (toggles, controls, bottom
    /// bar, dividers, padding). An estimate — the controller clamps the final frame to the screen,
    /// so a small error just means the expanded panel is slightly under 90%.
    private static let verticalChromeEstimate: CGFloat = 185

    /// Aspect (width / height) of the captured area: the region rect in region mode, otherwise the
    /// selected display's resolution. Falls back to 16:9. Stable inputs (not the per-frame image)
    /// so the size doesn't thrash while previewing.
    private var captureAspect: CGFloat {
        if captureRegionMode, captureRegionWidth > 1, captureRegionHeight > 1 {
            return CGFloat(captureRegionWidth / captureRegionHeight)
        }
        if captureDisplayID != 0,
           let display = availableDisplays.first(where: { Int($0.id) == captureDisplayID }),
           display.width > 0, display.height > 0 {
            return CGFloat(display.width) / CGFloat(display.height)
        }
        if let main = availableDisplays.first(where: { $0.isMain }) ?? availableDisplays.first,
           main.width > 0, main.height > 0 {
            return CGFloat(main.width) / CGFloat(main.height)
        }
        return 16.0 / 9.0
    }

    /// The screen the overlay sits on — the captured display (the panel follows it via
    /// `moveToDisplay`), falling back to the main screen. Used so an expanded panel is sized for
    /// the display it's actually on, not a larger one elsewhere.
    private var targetScreen: NSScreen? {
        if captureDisplayID != 0,
           let match = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                   .map(Int.init) == captureDisplayID
           }) {
            return match
        }
        return NSScreen.main
    }

    /// Size of the central preview box, aspect-fit to `captureAspect`. The panel width derives from
    /// this, and the preview fills the box exactly (no letterbox).
    private var previewBoxSize: CGSize {
        let aspect = max(0.1, captureAspect)
        if isExpanded {
            let screen = (targetScreen?.visibleFrame.size) ?? CGSize(width: 1440, height: 900)
            let availW = max(320, screen.width * Self.expandedScreenFraction - Self.horizontalChrome)
            let availH = max(240, screen.height * Self.expandedScreenFraction - Self.verticalChromeEstimate)
            let height = min(availH, availW / aspect)
            return CGSize(width: (height * aspect).rounded(), height: height.rounded())
        } else {
            let bounds = Self.compactPreviewBounds
            let height = min(bounds.height, bounds.width / aspect)
            return CGSize(width: (height * aspect).rounded(), height: height.rounded())
        }
    }

    private var panelWidth: CGFloat {
        max(Self.baseContentWidth, previewBoxSize.width + Self.horizontalChrome)
    }

    private var previewHeight: CGFloat { previewBoxSize.height }
    private var meterHeight: CGFloat { previewBoxSize.height }

    /// Resizes the floating panel to match the current content. Deferred to the next runloop tick
    /// so SwiftUI has applied the new layout before the controller reads its fitting size.
    private func schedulePanelResize() {
        DispatchQueue.main.async { onScaleChanged() }
    }

    private var sizeToggleButton: some View {
        Button {
            isExpanded.toggle()
            // Re-render the setup preview stream at a resolution matching the new size.
            Task { await refreshPreview() }
        } label: {
            Image(systemName: isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(6)
                .background(Circle().fill(Color.black.opacity(0.25)))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse preview" : "Expand preview to fill the screen")
    }

    var body: some View {
        panelContent
            .onAppear { handleOnAppear() }
            .onDisappear {
                isViewActive = false
                cancelSchedule()
            }
            .onChange(of: captureRegionMode) { _, newValue in
                // Leaving region mode tears down the selection overlay, so the toggle has nothing
                // to act on. Reset so we start fresh next time region mode is re-enabled.
                if !newValue && overlayClickThrough {
                    overlayClickThrough = false
                    onSetOverlayClickThrough(false)
                }
            }
            .onChange(of: captureManager.isRecording) { _, newValue in
                // Recording dismisses the region overlay too.
                if newValue && overlayClickThrough {
                    overlayClickThrough = false
                    onSetOverlayClickThrough(false)
                }
                // Setup ↔ recording views have different chrome heights — refit the panel.
                schedulePanelResize()
            }
            // Refit whenever the preview size changes (expand/collapse toggle, aspect change) or
            // the finalizing state swaps the chrome.
            .onChange(of: previewBoxSize) { _, _ in schedulePanelResize() }
            .onChange(of: captureManager.isProcessing) { _, _ in schedulePanelResize() }
            .task(id: scheduledStart) {
                guard let start = scheduledStart else { return }
                while !Task.isCancelled {
                    let remaining = start.timeIntervalSinceNow
                    if remaining <= 0 {
                        fireScheduledRecording()
                        return
                    }
                    scheduleCountdown = remaining
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
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
        .overlay(alignment: .topTrailing) {
            sizeToggleButton
        }
    }

    private func handleOnAppear() {
        isViewActive = true
        // Fit the panel to the content (the panel is created at a fixed initial size, and a
        // persisted expanded state needs the larger frame applied).
        schedulePanelResize()
        if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
            capturePresetRaw = CapturePreset.defaultPreset.rawValue
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
        .frame(width: panelWidth)
    }

    private var previewSection: some View {
        VStack(spacing: 6) {
            // Sys meter | Preview | Mic meter
            HStack(spacing: 6) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: meterHeight, chrome: false)
                    .opacity(captureIncludeSystemAudio ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("System audio level")

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
                .frame(height: previewHeight)

                AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: meterHeight, chrome: false)
                    .saturation(microphoneButtonActive ? 1.0 : 0.0)
                    .opacity(microphoneButtonActive ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("Microphone audio level")
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

                VirtualDisplayMenu(
                    captureDisplayID: $captureDisplayID,
                    isDisabled: captureManager.isRecording || captureManager.isProcessing
                ) {
                    await refreshAvailableDisplays()
                }
                .controlSize(.small)

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
                if captureRegionMode {
                    overlayClickThroughToggleButton
                    aspectRatioButton
                }
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
            if let start = scheduledStart {
                Button(action: cancelSchedule) {
                    Text("Cancel Schedule")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Starts \(Self.startTimeFormatter.string(from: start))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("in \(scheduleCountdownText)")
                            .font(.system(.callout, design: .monospaced))
                            .monospacedDigit()
                    }
                }
                .help("Mac will stay awake until the recording starts.")
            } else {
                Button(action: onCancel) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    scheduleStartDate = roundedScheduleDate(minutesFromNow: 5)
                    scheduleUseDuration = false
                    scheduleDurationHours = 0
                    scheduleDurationMinutes = 5
                    showSchedulePopover = true
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Schedule recording")
                .popover(isPresented: $showSchedulePopover, arrowEdge: .top) {
                    schedulePopoverContent
                }

                Button(action: handleRecord) {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Recording State View

    private var recordingStateView: some View {
        VStack(spacing: 0) {
            // Sys meter | Preview | Mic meter
            HStack(spacing: 6) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: meterHeight, chrome: false)
                    .opacity(captureIncludeSystemAudio ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("System audio level")

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
                .frame(height: previewHeight)

                AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: meterHeight, chrome: false)
                    .saturation(microphoneButtonActive ? 1.0 : 0.0)
                    .opacity(microphoneButtonActive ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("Microphone audio level")
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
                } else if let totalText = autoStopTotalText {
                    Text("\(elapsedText) / \(totalText)")
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
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
        .frame(width: panelWidth)
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

    private var lockedAspectRatio: AspectRatio {
        AspectRatio(rawValue: lockedAspectRatioRaw) ?? .free
    }

    /// Short label for the aspect ratio (e.g. "16:9", "1:1", "Free") — strips the parenthetical
    /// description that the full `displayName` carries for some cases.
    private var aspectRatioShortLabel: String {
        String(lockedAspectRatio.displayName.split(separator: " ").first ?? "Free")
    }

    private var aspectRatioButton: some View {
        Menu {
            ForEach(AspectRatio.allCases.filter { $0 != .ratio21_9 }) { ratio in
                Button {
                    lockedAspectRatioRaw = ratio.rawValue
                } label: {
                    if ratio == lockedAspectRatio {
                        Label(ratio.displayName, systemImage: "checkmark")
                    } else {
                        Text(ratio.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11, weight: .semibold))
                Text(aspectRatioShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(lockedAspectRatio == .free ? .primary : .accentColor)
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lockedAspectRatio == .free
                          ? Color.primary.opacity(0.06)
                          : Color.accentColor.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(lockedAspectRatio == .free
                            ? Color.primary.opacity(0.2)
                            : Color.accentColor,
                            lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(lockedAspectRatio == .free
              ? "Lock the recording region to an aspect ratio"
              : "Recording region locked to \(lockedAspectRatio.displayName) — choose another or Free to unlock")
    }

    private var overlayClickThroughToggleButton: some View {
        Button {
            overlayClickThrough.toggle()
            onSetOverlayClickThrough(overlayClickThrough)
        } label: {
            Image(systemName: overlayClickThrough ? "hand.raised.slash.fill" : "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(overlayClickThrough ? .orange : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(overlayClickThrough ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(overlayClickThrough ? Color.orange.opacity(0.6) : Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(overlayClickThrough
              ? "Selection overlay disabled — clicks pass through to other apps. Tip: hold ⌘ to pass through temporarily."
              : "Disable the selection overlay temporarily so clicks pass through. Tip: hold ⌘ for momentary pass-through.")
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

    // MARK: - Schedule

    private var schedulePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule Recording")
                .font(.headline)

            DatePicker("Start at", selection: $scheduleStartDate, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])

            Toggle("Auto-stop after", isOn: $scheduleUseDuration)

            if scheduleUseDuration {
                HStack(spacing: 4) {
                    Stepper(value: $scheduleDurationHours, in: 0...23) {
                        Text("\(scheduleDurationHours) hr")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 110)

                    Stepper(value: $scheduleDurationMinutes, in: 0...59) {
                        Text("\(scheduleDurationMinutes) min")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(width: 120)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    showSchedulePopover = false
                }
                Spacer()
                Button("Schedule") {
                    activateSchedule()
                    showSchedulePopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduleStartDate <= Date() || (scheduleUseDuration && scheduleDurationHours == 0 && scheduleDurationMinutes == 0))
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var scheduleCountdownText: String {
        let total = Int(scheduleCountdown)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var autoStopTotalText: String? {
        guard let stopDate = captureManager.autoStopDate else { return nil }
        let remaining = max(0, stopDate.timeIntervalSinceNow)
        let total = captureManager.elapsedTime + remaining
        return Self.durationFormatter.string(from: total)
    }

    private func roundedScheduleDate(minutesFromNow: Int) -> Date {
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .minute, value: minutesFromNow, to: Date()) ?? Date()
        // Round up to the next whole minute
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: future)
        components.second = 0
        return calendar.date(from: components) ?? future
    }

    private func activateSchedule() {
        scheduledStart = scheduleStartDate
        if scheduleUseDuration {
            let seconds = TimeInterval(scheduleDurationHours * 3600 + scheduleDurationMinutes * 60)
            scheduledDuration = seconds > 0 ? seconds : nil
        } else {
            scheduledDuration = nil
        }
        scheduleCountdown = scheduleStartDate.timeIntervalSinceNow
        if schedulePowerAssertion == nil {
            schedulePowerAssertion = PowerAssertion.shared.acquire(reason: "Waiting for scheduled screen recording")
        }
    }

    private func cancelSchedule() {
        scheduledStart = nil
        scheduledDuration = nil
        scheduleCountdown = 0
        PowerAssertion.shared.release(schedulePowerAssertion)
        schedulePowerAssertion = nil
    }

    private func fireScheduledRecording() {
        let duration = scheduledDuration
        scheduledStart = nil
        scheduledDuration = nil
        scheduleCountdown = 0
        PowerAssertion.shared.release(schedulePowerAssertion)
        schedulePowerAssertion = nil

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

            if let duration, duration > 0 {
                captureManager.setAutoStop(after: duration)
            }
        }
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

    private static let startTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
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
            regionRect: selectedRegionRect,
            maxPreviewWidth: previewPixelWidth
        )
    }

    /// Target pixel width for the live preview stream — matches the displayed preview box
    /// (in points) times the screen's backing scale so it stays sharp when the overlay is expanded.
    private var previewPixelWidth: CGFloat {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return max(1280, (previewBoxSize.width * backingScale).rounded(.up))
    }

    /// Re-fetch the display list after a virtual display is added/removed so it
    /// appears in (or disappears from) the picker.
    private func refreshAvailableDisplays() async {
        guard let content = try? await ScreenCaptureManager.shareableContent() else { return }
        let displays = ScreenCaptureManager.displays(from: content)
        await MainActor.run {
            availableDisplays = displays
        }
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
        let screen: NSScreen?
        if let displayID, let s = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            screen = s
        } else {
            screen = NSScreen.main ?? NSScreen.screens.first
        }
        guard let screen else { return } // no active displays — nothing to notify about
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
