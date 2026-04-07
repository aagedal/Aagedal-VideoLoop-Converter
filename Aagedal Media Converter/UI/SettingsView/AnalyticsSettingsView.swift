// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AnalyticsSettingsView: View {
    @AppStorage(AppConstants.analyticsVMAFModelKey) private var vmafModel = AppConstants.defaultAnalyticsVMAFModel
    @AppStorage(AppConstants.analyticsAutoRunKey) private var autoRunAfterConversion = false
    @AppStorage(AppConstants.analyticsAutoExportKey) private var autoExport = false
    @AppStorage(AppConstants.analyticsAutoExportFormatKey) private var autoExportFormat = AppConstants.defaultAnalyticsAutoExportFormat
    @AppStorage(AppConstants.ssimulacra2MaxFramesKey) private var ssimulacra2MaxFrames = AppConstants.defaultSSIMULACRA2MaxFrames

    @State private var enabledMetrics: Set<String> = []

    var body: some View {
        Form {
            metricsSection
            vmafSettingsSection
            ssimulacra2SettingsSection
            automationSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadEnabledMetrics()
        }
    }

    // MARK: - Quality Metrics Section

    private var metricsSection: some View {
        Section(header: Text("Quality Metrics")) {
            ForEach(QualityMetric.allCases, id: \.self) { metric in
                Toggle(isOn: Binding(
                    get: { enabledMetrics.contains(metric.rawValue) },
                    set: { enabled in
                        if enabled {
                            enabledMetrics.insert(metric.rawValue)
                        } else {
                            enabledMetrics.remove(metric.rawValue)
                        }
                        saveEnabledMetrics()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.displayName)
                        Text(metric.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - VMAF Settings Section

    private var vmafSettingsSection: some View {
        Section(header: Text("VMAF Settings")) {
            Picker("VMAF Model", selection: $vmafModel) {
                ForEach(VMAFModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }

            if let model = VMAFModel(rawValue: vmafModel) {
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - SSIMULACRA2 Settings Section

    private var ssimulacra2SettingsSection: some View {
        Section(header: Text("SSIMULACRA2 Settings")) {
            HStack {
                Text("ssimulacra2_rs")
                Spacer()
                if BinaryPathResolver.isSSIMULACRA2Available {
                    Label("Available", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Label("Not Found", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            if !BinaryPathResolver.isSSIMULACRA2Available {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requires Rust. Install Rust first, then the tool:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text("cargo install ssimulacra2_rs --no-default-features")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Stepper("Max Frames: \(ssimulacra2MaxFrames)", value: $ssimulacra2MaxFrames, in: 5...500, step: 5)

            Text("Number of frames sampled evenly across the video for comparison. More frames gives higher accuracy but takes longer.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Automation Section

    private var automationSection: some View {
        Section(header: Text("Automation")) {
            Toggle("Automatically run analytics after conversion", isOn: $autoRunAfterConversion)
            Text("When enabled, quality analytics will run on each file immediately after encoding completes.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Auto-export analytics results", isOn: $autoExport)

            if autoExport {
                Picker("Export Format", selection: $autoExportFormat) {
                    ForEach(AnalyticsExportFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }

                Text("Analytics results will be saved next to the encoded file after each analysis completes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About Quality Metrics")) {
            VStack(alignment: .leading, spacing: 12) {
                metricInfoRow(
                    name: "VMAF",
                    detail: "Video Multi-Method Assessment Fusion, developed by Netflix. Predicts perceived quality on a 0-100 scale. Scores above 93 are considered excellent."
                )
                metricInfoRow(
                    name: "PSNR",
                    detail: "Peak Signal-to-Noise Ratio. Traditional mathematical metric measured in dB. Higher values indicate better quality. Typical range: 30-50 dB."
                )
                metricInfoRow(
                    name: "XPSNR",
                    detail: "Extended PSNR by Fraunhofer HHI. Perceptually weighted PSNR metric measured in dB. Values above 42 dB are considered visually lossless."
                )
                metricInfoRow(
                    name: "SSIMULACRA2",
                    detail: "Perceptual quality metric by Cloudflare. Measures structural similarity on a 0-100 scale. Scores above 70 indicate good quality. Requires the external ssimulacra2_rs binary."
                )
            }
        }
    }

    private func metricInfoRow(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Persistence

    private func loadEnabledMetrics() {
        let saved = UserDefaults.standard.stringArray(forKey: AppConstants.analyticsEnabledMetricsKey)
            ?? AppConstants.defaultAnalyticsEnabledMetrics
        enabledMetrics = Set(saved)
    }

    private func saveEnabledMetrics() {
        UserDefaults.standard.set(Array(enabledMetrics), forKey: AppConstants.analyticsEnabledMetricsKey)
    }
}

#Preview {
    AnalyticsSettingsView()
}
