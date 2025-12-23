// Aagedal Media Converter — Presets Settings Tab

import SwiftUI

struct PresetsSettingsView: View {
    // Custom preset 1-3 settings
    @AppStorage(AppConstants.customPreset1CommandKey) private var customPreset1Command = AppConstants.defaultCustomPresetCommands[0]
    @AppStorage(AppConstants.customPreset1SuffixKey) private var customPreset1Suffix = AppConstants.defaultCustomPresetSuffixes[0]
    @AppStorage(AppConstants.customPreset1ExtensionKey) private var customPreset1Extension = AppConstants.defaultCustomPresetExtensions[0]
    @AppStorage(AppConstants.customPreset1NameKey) private var customPreset1Name = AppConstants.defaultCustomPresetNameSuffixes[0]
    @AppStorage(AppConstants.customPreset2CommandKey) private var customPreset2Command = AppConstants.defaultCustomPresetCommands[1]
    @AppStorage(AppConstants.customPreset2SuffixKey) private var customPreset2Suffix = AppConstants.defaultCustomPresetSuffixes[1]
    @AppStorage(AppConstants.customPreset2ExtensionKey) private var customPreset2Extension = AppConstants.defaultCustomPresetExtensions[1]
    @AppStorage(AppConstants.customPreset2NameKey) private var customPreset2Name = AppConstants.defaultCustomPresetNameSuffixes[1]
    @AppStorage(AppConstants.customPreset3CommandKey) private var customPreset3Command = AppConstants.defaultCustomPresetCommands[2]
    @AppStorage(AppConstants.customPreset3SuffixKey) private var customPreset3Suffix = AppConstants.defaultCustomPresetSuffixes[2]
    @AppStorage(AppConstants.customPreset3ExtensionKey) private var customPreset3Extension = AppConstants.defaultCustomPresetExtensions[2]
    @AppStorage(AppConstants.customPreset3NameKey) private var customPreset3Name = AppConstants.defaultCustomPresetNameSuffixes[2]

    // Custom preset 4-10 settings
    @AppStorage(AppConstants.customPreset4CommandKey) private var customPreset4Command = AppConstants.defaultCustomPresetCommands[3]
    @AppStorage(AppConstants.customPreset4SuffixKey) private var customPreset4Suffix = AppConstants.defaultCustomPresetSuffixes[3]
    @AppStorage(AppConstants.customPreset4ExtensionKey) private var customPreset4Extension = AppConstants.defaultCustomPresetExtensions[3]
    @AppStorage(AppConstants.customPreset4NameKey) private var customPreset4Name = AppConstants.defaultCustomPresetNameSuffixes[3]
    @AppStorage(AppConstants.customPreset5CommandKey) private var customPreset5Command = AppConstants.defaultCustomPresetCommands[4]
    @AppStorage(AppConstants.customPreset5SuffixKey) private var customPreset5Suffix = AppConstants.defaultCustomPresetSuffixes[4]
    @AppStorage(AppConstants.customPreset5ExtensionKey) private var customPreset5Extension = AppConstants.defaultCustomPresetExtensions[4]
    @AppStorage(AppConstants.customPreset5NameKey) private var customPreset5Name = AppConstants.defaultCustomPresetNameSuffixes[4]
    @AppStorage(AppConstants.customPreset6CommandKey) private var customPreset6Command = AppConstants.defaultCustomPresetCommands[5]
    @AppStorage(AppConstants.customPreset6SuffixKey) private var customPreset6Suffix = AppConstants.defaultCustomPresetSuffixes[5]
    @AppStorage(AppConstants.customPreset6ExtensionKey) private var customPreset6Extension = AppConstants.defaultCustomPresetExtensions[5]
    @AppStorage(AppConstants.customPreset6NameKey) private var customPreset6Name = AppConstants.defaultCustomPresetNameSuffixes[5]
    @AppStorage(AppConstants.customPreset7CommandKey) private var customPreset7Command = AppConstants.defaultCustomPresetCommands[6]
    @AppStorage(AppConstants.customPreset7SuffixKey) private var customPreset7Suffix = AppConstants.defaultCustomPresetSuffixes[6]
    @AppStorage(AppConstants.customPreset7ExtensionKey) private var customPreset7Extension = AppConstants.defaultCustomPresetExtensions[6]
    @AppStorage(AppConstants.customPreset7NameKey) private var customPreset7Name = AppConstants.defaultCustomPresetNameSuffixes[6]
    @AppStorage(AppConstants.customPreset8CommandKey) private var customPreset8Command = AppConstants.defaultCustomPresetCommands[7]
    @AppStorage(AppConstants.customPreset8SuffixKey) private var customPreset8Suffix = AppConstants.defaultCustomPresetSuffixes[7]
    @AppStorage(AppConstants.customPreset8ExtensionKey) private var customPreset8Extension = AppConstants.defaultCustomPresetExtensions[7]
    @AppStorage(AppConstants.customPreset8NameKey) private var customPreset8Name = AppConstants.defaultCustomPresetNameSuffixes[7]
    @AppStorage(AppConstants.customPreset9CommandKey) private var customPreset9Command = AppConstants.defaultCustomPresetCommands[8]
    @AppStorage(AppConstants.customPreset9SuffixKey) private var customPreset9Suffix = AppConstants.defaultCustomPresetSuffixes[8]
    @AppStorage(AppConstants.customPreset9ExtensionKey) private var customPreset9Extension = AppConstants.defaultCustomPresetExtensions[8]
    @AppStorage(AppConstants.customPreset9NameKey) private var customPreset9Name = AppConstants.defaultCustomPresetNameSuffixes[8]
    @AppStorage(AppConstants.customPreset10CommandKey) private var customPreset10Command = AppConstants.defaultCustomPresetCommands[9]
    @AppStorage(AppConstants.customPreset10SuffixKey) private var customPreset10Suffix = AppConstants.defaultCustomPresetSuffixes[9]
    @AppStorage(AppConstants.customPreset10ExtensionKey) private var customPreset10Extension = AppConstants.defaultCustomPresetExtensions[9]
    @AppStorage(AppConstants.customPreset10NameKey) private var customPreset10Name = AppConstants.defaultCustomPresetNameSuffixes[9]

    // Custom preset feature toggles
    @AppStorage(AppConstants.customPreset1ApplyCropKey) private var customPreset1ApplyCrop = false
    @AppStorage(AppConstants.customPreset1ApplyAudioRoutingKey) private var customPreset1ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset2ApplyCropKey) private var customPreset2ApplyCrop = false
    @AppStorage(AppConstants.customPreset2ApplyAudioRoutingKey) private var customPreset2ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset3ApplyCropKey) private var customPreset3ApplyCrop = false
    @AppStorage(AppConstants.customPreset3ApplyAudioRoutingKey) private var customPreset3ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset4ApplyCropKey) private var customPreset4ApplyCrop = false
    @AppStorage(AppConstants.customPreset4ApplyAudioRoutingKey) private var customPreset4ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset5ApplyCropKey) private var customPreset5ApplyCrop = false
    @AppStorage(AppConstants.customPreset5ApplyAudioRoutingKey) private var customPreset5ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset6ApplyCropKey) private var customPreset6ApplyCrop = false
    @AppStorage(AppConstants.customPreset6ApplyAudioRoutingKey) private var customPreset6ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset7ApplyCropKey) private var customPreset7ApplyCrop = false
    @AppStorage(AppConstants.customPreset7ApplyAudioRoutingKey) private var customPreset7ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset8ApplyCropKey) private var customPreset8ApplyCrop = false
    @AppStorage(AppConstants.customPreset8ApplyAudioRoutingKey) private var customPreset8ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset9ApplyCropKey) private var customPreset9ApplyCrop = false
    @AppStorage(AppConstants.customPreset9ApplyAudioRoutingKey) private var customPreset9ApplyAudioRouting = false
    @AppStorage(AppConstants.customPreset10ApplyCropKey) private var customPreset10ApplyCrop = false
    @AppStorage(AppConstants.customPreset10ApplyAudioRoutingKey) private var customPreset10ApplyAudioRouting = false

    // Custom preset activation toggles
    @AppStorage(AppConstants.customPreset1ActiveKey) private var customPreset1Active = false
    @AppStorage(AppConstants.customPreset2ActiveKey) private var customPreset2Active = false
    @AppStorage(AppConstants.customPreset3ActiveKey) private var customPreset3Active = false
    @AppStorage(AppConstants.customPreset4ActiveKey) private var customPreset4Active = false
    @AppStorage(AppConstants.customPreset5ActiveKey) private var customPreset5Active = false
    @AppStorage(AppConstants.customPreset6ActiveKey) private var customPreset6Active = false
    @AppStorage(AppConstants.customPreset7ActiveKey) private var customPreset7Active = false
    @AppStorage(AppConstants.customPreset8ActiveKey) private var customPreset8Active = false
    @AppStorage(AppConstants.customPreset9ActiveKey) private var customPreset9Active = false
    @AppStorage(AppConstants.customPreset10ActiveKey) private var customPreset10Active = false

    // ProRes profile
    @AppStorage(AppConstants.proResProfileKey) private var proResProfileRawValue = ProResProfile.standard.rawValue

    // Animated Still format
    @AppStorage(AppConstants.animatedStillFormatKey) private var animatedStillFormat = AppConstants.defaultAnimatedStillFormat

    // TV preset settings
    @AppStorage(AppConstants.tvFramerateModeKey) private var tvFramerateMode = AppConstants.defaultTVFramerateMode
    @AppStorage(AppConstants.tvResolutionLimitKey) private var tvResolutionLimit = AppConstants.defaultTVResolutionLimit

    // AVC-Intra settings
    @AppStorage(AppConstants.avcIntraClassKey) private var avcIntraClass = AppConstants.defaultAVCIntraClass
    @AppStorage(AppConstants.avcIntraAudioChannelsKey) private var avcIntraAudioChannels = AppConstants.defaultAVCIntraAudioChannels

    // Stream Copy container
    @AppStorage(AppConstants.streamCopyContainerKey) private var streamCopyContainer = AppConstants.defaultStreamCopyContainer

    // VideoLoop mute default
    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted

    // Proxy preset settings
    @AppStorage(AppConstants.proxyCodecKey) private var proxyCodec = AppConstants.defaultProxyCodec
    @AppStorage(AppConstants.proxyResolutionLimitKey) private var proxyResolutionLimit = AppConstants.defaultProxyResolutionLimit

    // H.264 preset settings
    @AppStorage(AppConstants.h264EncoderKey) private var h264Encoder = AppConstants.defaultH264Encoder
    @AppStorage(AppConstants.h264ContainerKey) private var h264Container = AppConstants.defaultH264Container
    @AppStorage(AppConstants.h264QualityKey) private var h264Quality = AppConstants.defaultH264Quality
    @AppStorage(AppConstants.h264SpeedKey) private var h264Speed = AppConstants.defaultH264Speed
    @AppStorage(AppConstants.h264ResolutionLimitKey) private var h264ResolutionLimit = AppConstants.defaultH264ResolutionLimit
    @AppStorage(AppConstants.h264BitrateKey) private var h264Bitrate = AppConstants.defaultH264Bitrate
    @AppStorage(AppConstants.h264AudioFormatKey) private var h264AudioFormat = AppConstants.defaultH264AudioFormat
    @AppStorage(AppConstants.h264AudioBitrateKey) private var h264AudioBitrate = AppConstants.defaultH264AudioBitrate

    // H.265 preset settings
    @AppStorage(AppConstants.h265EncoderKey) private var h265Encoder = AppConstants.defaultH265Encoder
    @AppStorage(AppConstants.h265ContainerKey) private var h265Container = AppConstants.defaultH265Container
    @AppStorage(AppConstants.h265QualityKey) private var h265Quality = AppConstants.defaultH265Quality
    @AppStorage(AppConstants.h265SpeedKey) private var h265Speed = AppConstants.defaultH265Speed
    @AppStorage(AppConstants.h265ResolutionLimitKey) private var h265ResolutionLimit = AppConstants.defaultH265ResolutionLimit
    @AppStorage(AppConstants.h265BitrateKey) private var h265Bitrate = AppConstants.defaultH265Bitrate
    @AppStorage(AppConstants.h265AudioFormatKey) private var h265AudioFormat = AppConstants.defaultH265AudioFormat
    @AppStorage(AppConstants.h265AudioBitrateKey) private var h265AudioBitrate = AppConstants.defaultH265AudioBitrate

    // AV1 preset settings
    @AppStorage(AppConstants.av1ContainerKey) private var av1Container = AppConstants.defaultAV1Container
    @AppStorage(AppConstants.av1QualityKey) private var av1Quality = AppConstants.defaultAV1Quality
    @AppStorage(AppConstants.av1SpeedKey) private var av1Speed = AppConstants.defaultAV1Speed
    @AppStorage(AppConstants.av1ResolutionLimitKey) private var av1ResolutionLimit = AppConstants.defaultAV1ResolutionLimit
    @AppStorage(AppConstants.av1AudioFormatKey) private var av1AudioFormat = AppConstants.defaultAV1AudioFormat
    @AppStorage(AppConstants.av1AudioBitrateKey) private var av1AudioBitrate = AppConstants.defaultAV1AudioBitrate

    // Built-in preset visibility (default to true)
    @AppStorage(AppConstants.videoLoopVisibleKey) private var videoLoopVisible = true
    @AppStorage(AppConstants.videoLoopWithSoundVisibleKey) private var videoLoopWithSoundVisible = true
    @AppStorage(AppConstants.animatedStillVisibleKey) private var animatedStillVisible = true
    @AppStorage(AppConstants.h264VisibleKey) private var h264Visible = true
    @AppStorage(AppConstants.h265VisibleKey) private var h265Visible = true
    @AppStorage(AppConstants.av1VisibleKey) private var av1Visible = true
    @AppStorage(AppConstants.tvHEVCVisibleKey) private var tvHEVCVisible = true
    @AppStorage(AppConstants.tvAVCIntraVisibleKey) private var tvAVCIntraVisible = true
    @AppStorage(AppConstants.proresVisibleKey) private var proresVisible = true
    @AppStorage(AppConstants.proxyVisibleKey) private var proxyVisible = true
    @AppStorage(AppConstants.streamCopyVisibleKey) private var streamCopyVisible = true
    @AppStorage(AppConstants.audioWAVVisibleKey) private var audioWAVVisible = true
    @AppStorage(AppConstants.audioAACVisibleKey) private var audioAACVisible = true

    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue

    @State private var selectedPreset: ExportPreset = .videoLoop
    @FocusState private var focusedCustomCommandSlot: Int?
    @State private var previousFocusedCustomCommandSlot: Int?

    var body: some View {
        HSplitView {
            // Left side: Preset list
            presetListView
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 250)

            // Right side: Preset details
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetDetailView
                    if selectedPreset.isCustom {
                        customPresetSection
                    }
                }
                .padding()
            }
            .frame(minWidth: 400)
        }
        .onAppear {
            selectedPreset = ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
        }
        .onChange(of: storedDefaultPresetRawValue) { _, newValue in
            selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
        }
        .onChange(of: focusedCustomCommandSlot) { _, newValue in
            if let previous = previousFocusedCustomCommandSlot, previous != newValue {
                finalizeCustomCommand(for: previous)
            }
            previousFocusedCustomCommandSlot = newValue
        }
        .onDisappear {
            if let previous = previousFocusedCustomCommandSlot {
                finalizeCustomCommand(for: previous)
                previousFocusedCustomCommandSlot = nil
            }
        }
    }

    // MARK: - Preset List View

    private var presetListView: some View {
        List(selection: $selectedPreset) {
            Section("Built-in Presets") {
                ForEach(ExportPreset.allCases.filter { !$0.isCustom }) { preset in
                    presetListRow(for: preset)
                        .tag(preset)
                }
            }

            Section("Custom Presets") {
                ForEach(ExportPreset.allCases.filter { $0.isCustom }) { preset in
                    presetListRow(for: preset)
                        .tag(preset)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func presetListRow(for preset: ExportPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(".\(preset.fileExtension)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if preset == defaultPreset {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Preset Detail View

    private var presetDetailView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with preset name and default button
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedPreset.displayName)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text(selectedPreset.fileSuffix)
                        Text(".\(selectedPreset.fileExtension)")
                    }
                    .font(.subheadline)
                    .monospaced()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                }

                Spacer()

                Button(action: setSelectedPresetAsDefault) {
                    if isSelectedPresetDefault {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    } else {
                        Text("Set as Default")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSelectedPresetDefault)
                .help(isSelectedPresetDefault ? "Current default preset" : "Set this preset as the default for new files")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)

            // Description
            Text(selectedPreset.description)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)

            // Preset-specific settings
            presetSpecificSettings
        }
    }

    @ViewBuilder
    private var presetSpecificSettings: some View {
        if selectedPreset == .prores {
            settingsCard {
                HStack {
                    Text("Format")
                    Spacer()
                    Picker("", selection: $proResProfileRawValue) {
                        ForEach(ProResProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .help("Select the ProRes profile for the output file.")
                }
            }
        }

        if selectedPreset == .animatedStill {
            settingsCard {
                HStack {
                    Text("Format")
                    Spacer()
                    Picker("", selection: $animatedStillFormat) {
                        ForEach(AnimatedStillFormat.availableCases) { format in
                            Text(format.rawValue).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .labelsHidden()
                    .help("Select the animated image format.")
                }
            }
        }

        if selectedPreset == .h264 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Encoder")
                        Spacer()
                        Picker("", selection: $h264Encoder) {
                            ForEach(H264Encoder.allCases) { encoder in
                                Text(encoder.rawValue).tag(encoder.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Hardware uses VideoToolbox for fast encoding. Software (libx264) offers better compression with CRF quality control.")
                    }

                    if H264Encoder(rawValue: h264Encoder) == .software {
                        HStack {
                            Text("Quality (CRF)")
                            Spacer()
                            Picker("", selection: $h264Quality) {
                                ForEach(CodecQualityLevel.allCases) { quality in
                                    Text(quality.rawValue).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Lower CRF values = higher quality and larger files. 23 is a good default for H.264.")
                        }

                        HStack {
                            Text("Encoding Speed")
                            Spacer()
                            Picker("", selection: $h264Speed) {
                                ForEach(EncodingSpeed.allCases) { speed in
                                    Text(speed.rawValue).tag(speed.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Slower presets produce better quality at the same file size.")
                        }
                    } else {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            TextField("10M", text: $h264Bitrate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .help("Target bitrate (e.g., 10M, 5000k)")
                        }
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $h264Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is most compatible. MOV is native to Apple. MKV supports all features but has less compatibility.")
                        .onChange(of: h264Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if h264AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                h264AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $h264ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $h264AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: h264Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: h264AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $h264AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .h265 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Encoder")
                        Spacer()
                        Picker("", selection: $h265Encoder) {
                            ForEach(H265Encoder.allCases) { encoder in
                                Text(encoder.rawValue).tag(encoder.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Hardware uses VideoToolbox for fast encoding. Software (libx265) offers better compression with CRF quality control.")
                    }

                    if H265Encoder(rawValue: h265Encoder) == .software {
                        HStack {
                            Text("Quality (CRF)")
                            Spacer()
                            Picker("", selection: $h265Quality) {
                                ForEach(CodecQualityLevel.allCases) { quality in
                                    Text(quality.rawValue).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Lower CRF values = higher quality and larger files. 28 is a good default for H.265.")
                        }

                        HStack {
                            Text("Encoding Speed")
                            Spacer()
                            Picker("", selection: $h265Speed) {
                                ForEach(EncodingSpeed.allCases) { speed in
                                    Text(speed.rawValue).tag(speed.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Slower presets produce better quality at the same file size.")
                        }
                    } else {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            TextField("8M", text: $h265Bitrate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .help("Target bitrate (e.g., 8M, 5000k)")
                        }
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $h265Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is most compatible. MOV is native to Apple. MKV supports all features but has less compatibility.")
                        .onChange(of: h265Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if h265AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                h265AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $h265ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $h265AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: h265Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: h265AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $h265AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .av1 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("AV1 encoding uses SVT-AV1 (software). No hardware acceleration available.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)

                    HStack {
                        Text("Quality (CRF)")
                        Spacer()
                        Picker("", selection: $av1Quality) {
                            ForEach(AV1QualityLevel.allCases) { quality in
                                Text(quality.rawValue).tag(quality.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Lower CRF values = higher quality and larger files. 30 is the SVT-AV1 default.")
                    }

                    HStack {
                        Text("Encoding Speed (Preset)")
                        Spacer()
                        Picker("", selection: $av1Speed) {
                            ForEach(AV1EncodingSpeed.allCases) { speed in
                                Text(speed.displayName).tag(speed.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("0 = slowest/best quality, 13 = fastest. 6 is a balanced default.")
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $av1Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is most compatible. MKV supports all AV1 features.")
                        .onChange(of: av1Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if av1AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                av1AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $av1ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $av1AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: av1Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: av1AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $av1AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .tvHEVC {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Framerate")
                        Spacer()
                        Picker("", selection: $tvFramerateMode) {
                            ForEach(TVFramerateMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Source keeps original framerate. Interlaced modes (50i, 59.94i) apply field-based encoding.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $tvResolutionLimit) {
                            ForEach(TVResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit output resolution. Bitrate scales automatically with resolution.")
                    }
                }
            }
        }

        if selectedPreset == .tvAVCIntra {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("AVC-Intra Class")
                        Spacer()
                        Picker("", selection: $avcIntraClass) {
                            ForEach(AVCIntraClass.allCases) { avcClass in
                                Text(avcClass.rawValue).tag(avcClass.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Select the AVC-Intra bitrate class. Higher classes provide better quality.")
                    }
                    HStack {
                        Text("Audio Channels")
                        Spacer()
                        Picker("", selection: $avcIntraAudioChannels) {
                            ForEach(AVCIntraAudioChannels.allCases) { channels in
                                Text(channels.rawValue).tag(channels.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Number of mono audio channels in output. Source audio is mapped to first two channels.")
                    }
                    HStack {
                        Text("Framerate")
                        Spacer()
                        Picker("", selection: $tvFramerateMode) {
                            ForEach(TVFramerateMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Source keeps original framerate. Interlaced modes (50i, 59.94i) apply field-based encoding.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $tvResolutionLimit) {
                            ForEach(TVResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit output resolution. Bitrate scales automatically with resolution.")
                    }
                }
            }
        }

        if selectedPreset == .streamCopy {
            settingsCard {
                HStack {
                    Text("Container")
                    Spacer()
                    Picker("", selection: $streamCopyContainer) {
                        ForEach(StreamCopyContainer.allCases) { container in
                            Text(container.rawValue).tag(container.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .labelsHidden()
                    .help("Choose output container format, or keep the source format.")
                }
            }
        }

        if selectedPreset == .proxy {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Codec")
                        Spacer()
                        Picker("", selection: $proxyCodec) {
                            ForEach(ProxyCodec.allCases) { codec in
                                Text(codec.rawValue).tag(codec.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Select the codec for proxy files. HEVC is most efficient, ProRes Proxy is widely compatible, DNx is for Avid workflows.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $proxyResolutionLimit) {
                            ForEach(ProxyResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit proxy resolution. Lower resolutions create smaller files for faster editing.")
                    }
                }
            }
        }

        if selectedPreset == .videoLoop {
            settingsCard {
                Toggle(isOn: $videoLoopDefaultMuted) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute audio by default")
                            .font(.subheadline)
                        Text("When enabled, new files will be muted automatically when VideoLoop is selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
            }
        }

        // Visibility toggle for built-in presets
        if !selectedPreset.isCustom {
            settingsCard {
                Toggle(isOn: visibilityBinding(for: selectedPreset)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in preset picker")
                            .font(.subheadline)
                        Text(isSelectedPresetDefault
                             ? "The default preset cannot be hidden"
                             : "When disabled, this preset will be hidden from the preset picker")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(isSelectedPresetDefault)
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
    }

    @ViewBuilder
    private var customPresetSection: some View {
        let slot = selectedPreset.customSlotIndex ?? 0
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            Text("Custom Preset Configuration")
                .font(.headline)
                .padding(.top, 8)

            // Activation toggle for all custom presets
            settingsCard {
                Toggle(isOn: Binding(
                    get: { isCustomPresetActiveBinding(for: slot) },
                    set: { setCustomPresetActive($0, slot: slot) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activate Preset")
                            .font(.subheadline)
                        Text(isSelectedPresetDefault
                             ? "The default preset cannot be deactivated"
                             : "When disabled, this preset will be hidden from the preset picker")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(isSelectedPresetDefault)
            }

            presetNameField(for: slot)

            VStack(alignment: .leading, spacing: 12) {
                Text("Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: Binding(
                    get: { customCommand(for: slot) },
                    set: { updateCustomCommand($0, slot: slot) }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .focused($focusedCustomCommandSlot, equals: slot)
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Feature Support")
                        .font(.subheadline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { applyCrop(for: slot) },
                            set: { updateApplyCrop($0, slot: slot) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply crop configuration")
                                    .font(.subheadline)
                                Text("When enabled, crop settings will be applied to files using this preset")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle())

                        Toggle(isOn: Binding(
                            get: { applyAudioRouting(for: slot) },
                            set: { updateApplyAudioRouting($0, slot: slot) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply audio routing configuration")
                                    .font(.subheadline)
                                Text("When enabled, audio track routing will be applied to files using this preset")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle())
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output file suffix")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextField("_c\(slot + 1)", text: Binding(
                        get: { customSuffix(for: slot) },
                        set: { updateCustomSuffix($0, slot: slot) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output extension")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextField("mp4", text: Binding(
                        get: { customExtension(for: slot) },
                        set: { updateCustomExtension($0, slot: slot) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Text("Example: `-c:v libx264 -crf 18 -preset slow -c:a copy` produces `filename\(customSuffix(for: slot)).\(customExtension(for: slot))`.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers (scoped to Presets tab)

    private var defaultPreset: ExportPreset {
        ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
    }

    private var isSelectedPresetDefault: Bool {
        selectedPreset == defaultPreset
    }

    private func setSelectedPresetAsDefault() {
        // Ensure the preset is visible/active before setting as default
        if let slot = selectedPreset.customSlotIndex {
            // Custom preset: activate it
            setCustomPresetActive(true, slot: slot)
        } else {
            // Built-in preset: make it visible
            visibilityBinding(for: selectedPreset).wrappedValue = true
        }
        storedDefaultPresetRawValue = selectedPreset.rawValue
    }

    private func customCommand(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Command
        case 1: return customPreset2Command
        case 2: return customPreset3Command
        case 3: return customPreset4Command
        case 4: return customPreset5Command
        case 5: return customPreset6Command
        case 6: return customPreset7Command
        case 7: return customPreset8Command
        case 8: return customPreset9Command
        case 9: return customPreset10Command
        default:
            return AppConstants.defaultCustomPresetCommands.indices.contains(slot)
                ? AppConstants.defaultCustomPresetCommands[slot]
                : "-c copy"
        }
    }

    private func customSuffix(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Suffix
        case 1: return customPreset2Suffix
        case 2: return customPreset3Suffix
        case 3: return customPreset4Suffix
        case 4: return customPreset5Suffix
        case 5: return customPreset6Suffix
        case 6: return customPreset7Suffix
        case 7: return customPreset8Suffix
        case 8: return customPreset9Suffix
        case 9: return customPreset10Suffix
        default:
            return AppConstants.defaultCustomPresetSuffixes.indices.contains(slot)
                ? AppConstants.defaultCustomPresetSuffixes[slot]
                : "_c\(slot + 1)"
        }
    }

    private func customExtension(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Extension
        case 1: return customPreset2Extension
        case 2: return customPreset3Extension
        case 3: return customPreset4Extension
        case 4: return customPreset5Extension
        case 5: return customPreset6Extension
        case 6: return customPreset7Extension
        case 7: return customPreset8Extension
        case 8: return customPreset9Extension
        case 9: return customPreset10Extension
        default:
            return AppConstants.defaultCustomPresetExtensions.indices.contains(slot)
                ? AppConstants.defaultCustomPresetExtensions[slot]
                : "mp4"
        }
    }

    private func applyCrop(for slot: Int) -> Bool {
        switch slot {
        case 0: return customPreset1ApplyCrop
        case 1: return customPreset2ApplyCrop
        case 2: return customPreset3ApplyCrop
        case 3: return customPreset4ApplyCrop
        case 4: return customPreset5ApplyCrop
        case 5: return customPreset6ApplyCrop
        case 6: return customPreset7ApplyCrop
        case 7: return customPreset8ApplyCrop
        case 8: return customPreset9ApplyCrop
        case 9: return customPreset10ApplyCrop
        default: return false
        }
    }

    private func applyAudioRouting(for slot: Int) -> Bool {
        switch slot {
        case 0: return customPreset1ApplyAudioRouting
        case 1: return customPreset2ApplyAudioRouting
        case 2: return customPreset3ApplyAudioRouting
        case 3: return customPreset4ApplyAudioRouting
        case 4: return customPreset5ApplyAudioRouting
        case 5: return customPreset6ApplyAudioRouting
        case 6: return customPreset7ApplyAudioRouting
        case 7: return customPreset8ApplyAudioRouting
        case 8: return customPreset9ApplyAudioRouting
        case 9: return customPreset10ApplyAudioRouting
        default: return false
        }
    }

    private func updateApplyCrop(_ value: Bool, slot: Int) {
        switch slot {
        case 0: customPreset1ApplyCrop = value
        case 1: customPreset2ApplyCrop = value
        case 2: customPreset3ApplyCrop = value
        case 3: customPreset4ApplyCrop = value
        case 4: customPreset5ApplyCrop = value
        case 5: customPreset6ApplyCrop = value
        case 6: customPreset7ApplyCrop = value
        case 7: customPreset8ApplyCrop = value
        case 8: customPreset9ApplyCrop = value
        case 9: customPreset10ApplyCrop = value
        default: break
        }
    }

    private func updateApplyAudioRouting(_ value: Bool, slot: Int) {
        switch slot {
        case 0: customPreset1ApplyAudioRouting = value
        case 1: customPreset2ApplyAudioRouting = value
        case 2: customPreset3ApplyAudioRouting = value
        case 3: customPreset4ApplyAudioRouting = value
        case 4: customPreset5ApplyAudioRouting = value
        case 5: customPreset6ApplyAudioRouting = value
        case 6: customPreset7ApplyAudioRouting = value
        case 7: customPreset8ApplyAudioRouting = value
        case 8: customPreset9ApplyAudioRouting = value
        case 9: customPreset10ApplyAudioRouting = value
        default: break
        }
    }

    private func isCustomPresetActiveBinding(for slot: Int) -> Bool {
        switch slot {
        case 0: return customPreset1Active
        case 1: return customPreset2Active
        case 2: return customPreset3Active
        case 3: return customPreset4Active
        case 4: return customPreset5Active
        case 5: return customPreset6Active
        case 6: return customPreset7Active
        case 7: return customPreset8Active
        case 8: return customPreset9Active
        case 9: return customPreset10Active
        default: return false
        }
    }

    private func setCustomPresetActive(_ value: Bool, slot: Int) {
        switch slot {
        case 0: customPreset1Active = value
        case 1: customPreset2Active = value
        case 2: customPreset3Active = value
        case 3: customPreset4Active = value
        case 4: customPreset5Active = value
        case 5: customPreset6Active = value
        case 6: customPreset7Active = value
        case 7: customPreset8Active = value
        case 8: customPreset9Active = value
        case 9: customPreset10Active = value
        default: break
        }
    }

    private func visibilityBinding(for preset: ExportPreset) -> Binding<Bool> {
        switch preset {
        case .videoLoop:
            return $videoLoopVisible
        case .videoLoopWithSound:
            return $videoLoopWithSoundVisible
        case .animatedStill:
            return $animatedStillVisible
        case .h264:
            return $h264Visible
        case .h265:
            return $h265Visible
        case .av1:
            return $av1Visible
        case .tvHEVC:
            return $tvHEVCVisible
        case .tvAVCIntra:
            return $tvAVCIntraVisible
        case .prores:
            return $proresVisible
        case .proxy:
            return $proxyVisible
        case .streamCopy:
            return $streamCopyVisible
        case .audioUncompressedWAV:
            return $audioWAVVisible
        case .audioStereoAAC:
            return $audioAACVisible
        default:
            // Custom presets use activation, not visibility
            return .constant(true)
        }
    }

    private func customNamePrefix(for slot: Int) -> String {
        let prefixes = AppConstants.customPresetPrefixes
        return prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
    }

    private func customNameSuffix(for slot: Int) -> String {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let stored: String
        switch slot {
        case 0: stored = customPreset1Name
        case 1: stored = customPreset2Name
        case 2: stored = customPreset3Name
        case 3: stored = customPreset4Name
        case 4: stored = customPreset5Name
        case 5: stored = customPreset6Name
        case 6: stored = customPreset7Name
        case 7: stored = customPreset8Name
        case 8: stored = customPreset9Name
        case 9: stored = customPreset10Name
        default: stored = fallback
        }
        let sanitized = sanitizeCustomNameSuffix(stored, prefix: prefix, fallback: fallback)
        if sanitized != stored {
            updateStoredNameSuffix(sanitized, slot: slot)
        }
        return sanitized
    }

    private func customDisplayName(for slot: Int) -> String {
        "\(customNamePrefix(for: slot)) \(customNameSuffix(for: slot))"
    }

    private func updateCustomCommand(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetCommands
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "-c copy"
        let sanitized = sanitizeCustomCommand(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Command = sanitized
        case 1: customPreset2Command = sanitized
        case 2: customPreset3Command = sanitized
        case 3: customPreset4Command = sanitized
        case 4: customPreset5Command = sanitized
        case 5: customPreset6Command = sanitized
        case 6: customPreset7Command = sanitized
        case 7: customPreset8Command = sanitized
        case 8: customPreset9Command = sanitized
        case 9: customPreset10Command = sanitized
        default: break
        }
    }

    private func updateCustomSuffix(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetSuffixes
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "_c\(slot + 1)"
        let sanitized = sanitizeCustomSuffix(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Suffix = sanitized
        case 1: customPreset2Suffix = sanitized
        case 2: customPreset3Suffix = sanitized
        case 3: customPreset4Suffix = sanitized
        case 4: customPreset5Suffix = sanitized
        case 5: customPreset6Suffix = sanitized
        case 6: customPreset7Suffix = sanitized
        case 7: customPreset8Suffix = sanitized
        case 8: customPreset9Suffix = sanitized
        case 9: customPreset10Suffix = sanitized
        default: break
        }
    }

    private func updateCustomExtension(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetExtensions
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "mp4"
        let sanitized = sanitizeCustomExtension(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Extension = sanitized
        case 1: customPreset2Extension = sanitized
        case 2: customPreset3Extension = sanitized
        case 3: customPreset4Extension = sanitized
        case 4: customPreset5Extension = sanitized
        case 5: customPreset6Extension = sanitized
        case 6: customPreset7Extension = sanitized
        case 7: customPreset8Extension = sanitized
        case 8: customPreset9Extension = sanitized
        case 9: customPreset10Extension = sanitized
        default: break
        }
    }

    private func updateCustomNameSuffix(_ value: String, slot: Int) {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let sanitized = sanitizeCustomNameSuffix(value, prefix: prefix, fallback: fallback)
        updateStoredNameSuffix(sanitized, slot: slot)
    }

    private func updateStoredNameSuffix(_ value: String, slot: Int) {
        switch slot {
        case 0: customPreset1Name = value
        case 1: customPreset2Name = value
        case 2: customPreset3Name = value
        case 3: customPreset4Name = value
        case 4: customPreset5Name = value
        case 5: customPreset6Name = value
        case 6: customPreset7Name = value
        case 7: customPreset8Name = value
        case 8: customPreset9Name = value
        case 9: customPreset10Name = value
        default: break
        }
    }

    @ViewBuilder
    private func presetNameField(for slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display name")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text(customNamePrefix(for: slot))
                    .font(.body.monospaced())
                TextField("Custom Preset", text: Binding(
                    get: { customNameSuffix(for: slot) },
                    set: { updateCustomNameSuffix($0, slot: slot) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func sanitizeCustomSuffix(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("_") ? trimmed : "_" + trimmed
    }

    private func sanitizeCustomExtension(_ value: String, fallback: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? fallback : trimmed.lowercased()
    }

    private func sanitizeCustomCommand(_ value: String, fallback: String) -> String {
        let withoutControlCharacters = value.trimmingCharacters(in: .controlCharacters)
        let trimmedWhitespace = withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhitespace.isEmpty {
            return fallback
        }
        return withoutControlCharacters
    }

    private func finalizeCustomCommand(for slot: Int) {
        let current = customCommand(for: slot)
        let trimmedTrailing = trimTrailingWhitespace(from: current)
        updateCustomCommand(trimmedTrailing, slot: slot)
    }

    private func trimTrailingWhitespace(from value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lowercasedPrefix = prefix.lowercased()
        var remainder = trimmed
        if trimmed.lowercased().hasPrefix(lowercasedPrefix) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            remainder = String(trimmed[cutoff...])
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.first == ":" {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }


}
