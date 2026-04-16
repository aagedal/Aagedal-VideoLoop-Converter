// Aagedal Media Converter — Waveform Settings Tab

import SwiftUI

/// Short edge resolution options for waveform video
enum ShortEdgeResolution: Int, CaseIterable, Identifiable {
    case p2160 = 2160
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .p2160: return "2160p (4K)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}

struct WaveformSettingsView: View {
    @AppStorage(AppConstants.audioWaveformVideoDefaultEnabledKey) private var waveformVideoDefaultEnabled = true
    @AppStorage(AppConstants.audioWaveformAspectRatioKey) private var waveformAspectRatioRaw = AppConstants.defaultAudioWaveformAspectRatio
    @AppStorage(AppConstants.audioWaveformShortEdgeKey) private var waveformShortEdge = AppConstants.defaultAudioWaveformShortEdge
    @AppStorage(AppConstants.audioWaveformBackgroundColorKey) private var waveformBackgroundHex = "#000000"
    @AppStorage(AppConstants.audioWaveformForegroundColorKey) private var waveformForegroundHex = "#FFFFFF"
    @AppStorage(AppConstants.audioWaveformNormalizeKey) private var waveformNormalizeAudio = false
    @AppStorage(AppConstants.audioWaveformStyleKey) private var waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
    @AppStorage(AppConstants.audioWaveformFrameRateKey) private var waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate
    @AppStorage(AppConstants.audioWaveformRenderingEngineKey) private var waveformRenderingEngineRaw = "swift"
    @AppStorage(AppConstants.audioWaveformSwiftStyleKey) private var waveformSwiftStyleRaw = "capsules"
    @AppStorage(AppConstants.audioWaveformBandCountKey) private var waveformBandCount = 32
    @AppStorage(AppConstants.audioWaveformFrequencyDistributionKey) private var waveformFrequencyDistributionRaw = "mel"

    // Gradient settings
    @AppStorage(AppConstants.audioWaveformForegroundGradientEnabledKey) private var foregroundGradientEnabled = false
    @AppStorage(AppConstants.audioWaveformForegroundGradientEndColorKey) private var foregroundGradientEndHex = "#FF0000"
    @AppStorage(AppConstants.audioWaveformBackgroundGradientEnabledKey) private var backgroundGradientEnabled = false
    @AppStorage(AppConstants.audioWaveformBackgroundGradientEndColorKey) private var backgroundGradientEndHex = "#333333"

    // Opacity setting
    @AppStorage(AppConstants.audioWaveformOpacityKey) private var waveformOpacity = 1.0

    private var isSwiftEngine: Bool {
        (WaveformRenderingEngine(rawValue: waveformRenderingEngineRaw) ?? .swift) == .swift
    }

    private var selectedRenderingEngine: Binding<WaveformRenderingEngine> {
        Binding(
            get: { WaveformRenderingEngine(rawValue: waveformRenderingEngineRaw) ?? .swift },
            set: { waveformRenderingEngineRaw = $0.rawValue }
        )
    }

    private var selectedSwiftStyle: Binding<SwiftWaveformStyle> {
        Binding(
            get: { SwiftWaveformStyle(rawValue: waveformSwiftStyleRaw) ?? .capsules },
            set: { waveformSwiftStyleRaw = $0.rawValue }
        )
    }

    private var selectedAspectRatio: Binding<AspectRatio> {
        Binding(
            get: { AspectRatio(rawValue: waveformAspectRatioRaw) ?? .ratio16_9 },
            set: { waveformAspectRatioRaw = $0.rawValue }
        )
    }

    private var selectedShortEdge: Binding<ShortEdgeResolution> {
        Binding(
            get: { ShortEdgeResolution(rawValue: waveformShortEdge) ?? .p1080 },
            set: { waveformShortEdge = $0.rawValue }
        )
    }

    /// Computed resolution string for display
    private var computedResolution: String {
        let aspectRatio = AspectRatio(rawValue: waveformAspectRatioRaw) ?? .ratio16_9
        let shortEdge = waveformShortEdge
        let (width, height) = AudioWaveformPreferences.computeResolution(aspectRatio: aspectRatio, shortEdge: shortEdge)
        return "\(width)x\(height)"
    }

    var body: some View {
        Form {
            waveformSection
        }
        .formStyle(.grouped)
        .onDisappear {
            sanitizeWaveformColors()
        }
    }

    private var waveformSection: some View {
        Section(header: Text("Audio Waveform Video")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable waveform video by default", isOn: $waveformVideoDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, newly added audio-only files will generate waveform videos unless disabled per item.")

                Divider()
                    .padding(.vertical, 4)

                Toggle("Normalize audio levels", isOn: $waveformNormalizeAudio)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Applies dynamic normalization before rendering the waveform and exporting audio to keep amplitudes consistent.")

                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aspect Ratio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: selectedAspectRatio) {
                            ForEach(AspectRatio.allCases.filter { $0 != .free }) { ratio in
                                Text(ratio.displayName).tag(ratio)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Short Edge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: selectedShortEdge) {
                            ForEach(ShortEdgeResolution.allCases) { resolution in
                                Text(resolution.displayName).tag(resolution)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(computedResolution)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Frame Rate", selection: Binding(
                        get: { Int(waveformFrameRate.rounded()) },
                        set: { waveformFrameRate = Double($0) }
                    )) {
                        ForEach([15, 24, 25, 30, 50, 60], id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Controls waveform animation smoothness. Higher frame rates increase render cost.")
                }

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    Picker("Rendering engine", selection: selectedRenderingEngine) {
                        ForEach(WaveformRenderingEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .help("Swift renders capsule-style frequency visualizer natively. FFmpeg uses classic waveform filters.")
                }

                if isSwiftEngine {
                    swiftEngineSettings
                } else {
                    ffmpegEngineSettings
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        resetWaveformDefaults()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Restore waveform color and normalization settings to their default values.")
                }.padding(.top, 15)

                Text("These defaults control waveform video generation for audio-only media. Colors should be six-digit HEX values.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    // MARK: - Swift Engine Settings

    @ViewBuilder
    private var swiftEngineSettings: some View {
        HStack {
            Picker("Visual style", selection: selectedSwiftStyle) {
                ForEach(SwiftWaveformStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .help("Choose the visual appearance for the native Swift waveform renderer.")
        }

        HStack(spacing: 16) {
            Picker("Bands", selection: $waveformBandCount) {
                ForEach([16, 24, 32, 48, 64], id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .help("Number of frequency bands (capsules, bars, or wire points).")

            Picker("Distribution", selection: Binding(
                get: { FrequencyDistribution(rawValue: waveformFrequencyDistributionRaw) ?? .mel },
                set: { waveformFrequencyDistributionRaw = $0.rawValue }
            )) {
                ForEach(FrequencyDistribution.allCases) { dist in
                    Text(dist.displayName).tag(dist)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .help("How frequency ranges are mapped to bands. Mel Scale matches human hearing perception.")
        }

        swiftColorSettingsGroup

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Waveform Opacity")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(waveformOpacity * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $waveformOpacity, in: 0.5...1.0, step: 0.05)
                .help("Controls transparency of the waveform over background images. Lower values let the background show through.")
        }
    }

    // MARK: - FFmpeg Engine Settings

    @ViewBuilder
    private var ffmpegEngineSettings: some View {
        HStack {
            Picker(
                "Waveform style",
                selection: Binding(
                    get: { WaveformStyle(rawValue: waveformStyleRaw) ?? .linear },
                    set: { waveformStyleRaw = $0.rawValue }
                )
            ) {
                ForEach(WaveformStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .help("Choose the visual appearance used when rendering waveform videos (FFmpeg engine only).")
        }

        ffmpegColorSettingsGroup
    }

    // MARK: - Swift Color Settings (with gradient support)

    private var swiftColorSettingsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Foreground color + gradient
                colorPickerRow(
                    title: "Foreground Color",
                    binding: $waveformForegroundHex,
                    placeholder: ""
                )

                HStack(spacing: 8) {
                    Toggle("Gradient", isOn: $foregroundGradientEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .fixedSize()
                    if foregroundGradientEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ColorPicker(selection: Binding(
                                get: { Color(hex: foregroundGradientEndHex) },
                                set: { foregroundGradientEndHex = $0.toHexString(includeHash: true) }
                            ), supportsOpacity: false) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .frame(width: 36)
                            TextField("", text: $foregroundGradientEndHex)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .onSubmit(sanitizeWaveformColors)
                        }
                    }
                }
                .padding(.leading, 20)

                Divider()

                // Background color + gradient
                colorPickerRow(
                    title: "Background Color",
                    binding: $waveformBackgroundHex,
                    placeholder: ""
                )

                HStack(spacing: 8) {
                    Toggle("Gradient", isOn: $backgroundGradientEnabled)
                        .toggleStyle(SwitchToggleStyle())
                        .fixedSize()
                    if backgroundGradientEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ColorPicker(selection: Binding(
                                get: { Color(hex: backgroundGradientEndHex) },
                                set: { backgroundGradientEndHex = $0.toHexString(includeHash: true) }
                            ), supportsOpacity: false) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .frame(width: 36)
                            TextField("", text: $backgroundGradientEndHex)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .onSubmit(sanitizeWaveformColors)
                        }
                    }
                }
                .padding(.leading, 20)
            }
            .padding(8)
        } label: {
            Label("Colors", systemImage: "paintpalette")
        }.padding(.bottom, 5)
    }

    // MARK: - FFmpeg Color Settings (solid colors only)

    private var ffmpegColorSettingsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                colorPickerRow(
                    title: "Foreground Color",
                    binding: $waveformForegroundHex,
                    placeholder: ""
                )

                Divider()

                colorPickerRow(
                    title: "Background Color",
                    binding: $waveformBackgroundHex,
                    placeholder: ""
                )
            }
            .padding(8)
        } label: {
            Label("Colors", systemImage: "paintpalette")
        }.padding(.bottom, 5)
    }

    @ViewBuilder
    private func colorPickerRow(title: String, binding: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ColorPicker(selection: Binding(
                    get: { Color(hex: binding.wrappedValue) },
                    set: { binding.wrappedValue = $0.toHexString(includeHash: true) }
                ), supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
                .frame(width: 36)

                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sanitizeWaveformColors)
            }.padding(.leading, 15)
        }.padding(.leading, 5)
    }

    // MARK: - Helpers (scoped to Waveform tab)

    private func sanitizeWaveformColors() {
        waveformBackgroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformBackgroundHex, fallback: "000000")
        waveformForegroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformForegroundHex, fallback: "FFFFFF")
        foregroundGradientEndHex = "#" + AudioWaveformPreferences.sanitizeHex(foregroundGradientEndHex, fallback: "FF0000")
        backgroundGradientEndHex = "#" + AudioWaveformPreferences.sanitizeHex(backgroundGradientEndHex, fallback: "333333")
    }

    private func resetWaveformDefaults() {
        waveformVideoDefaultEnabled = true
        waveformAspectRatioRaw = AppConstants.defaultAudioWaveformAspectRatio
        waveformShortEdge = AppConstants.defaultAudioWaveformShortEdge
        waveformBackgroundHex = "#000000"
        waveformForegroundHex = "#FFFFFF"
        waveformNormalizeAudio = false
        waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
        waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate
        waveformRenderingEngineRaw = "swift"
        waveformSwiftStyleRaw = "capsules"
        waveformBandCount = 32
        waveformFrequencyDistributionRaw = "mel"
        foregroundGradientEnabled = false
        foregroundGradientEndHex = "#FF0000"
        backgroundGradientEnabled = false
        backgroundGradientEndHex = "#333333"
        waveformOpacity = 1.0
    }
}
