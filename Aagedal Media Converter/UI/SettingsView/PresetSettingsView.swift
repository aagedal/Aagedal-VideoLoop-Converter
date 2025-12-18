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

    // Built-in preset visibility (default to true)
    @AppStorage(AppConstants.videoLoopVisibleKey) private var videoLoopVisible = true
    @AppStorage(AppConstants.videoLoopWithAudioVisibleKey) private var videoLoopWithAudioVisible = true
    @AppStorage(AppConstants.tvHEVCVisibleKey) private var tvHEVCVisible = true
    @AppStorage(AppConstants.tvAVCIntraVisibleKey) private var tvAVCIntraVisible = true
    @AppStorage(AppConstants.proresVisibleKey) private var proresVisible = true
    @AppStorage(AppConstants.streamCopyVisibleKey) private var streamCopyVisible = true
    @AppStorage(AppConstants.animatedStillVisibleKey) private var animatedStillVisible = true
    @AppStorage(AppConstants.hevcProxyVisibleKey) private var hevcProxyVisible = true
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
                        ForEach(AnimatedStillFormat.allCases) { format in
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
        case .videoLoopWithAudio:
            return $videoLoopWithAudioVisible
        case .tvHEVC:
            return $tvHEVCVisible
        case .tvAVCIntra:
            return $tvAVCIntraVisible
        case .prores:
            return $proresVisible
        case .streamCopy:
            return $streamCopyVisible
        case .animatedStill:
            return $animatedStillVisible
        case .hevcProxy1080p:
            return $hevcProxyVisible
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
