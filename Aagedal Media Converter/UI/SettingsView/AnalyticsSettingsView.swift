// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AnalyticsSettingsView: View {
    @AppStorage(AppConstants.analyticsVMAFModelKey) private var vmafModel = AppConstants.defaultAnalyticsVMAFModel
    @AppStorage(AppConstants.analyticsExportFormatKey) private var exportFormat = AppConstants.defaultAnalyticsExportFormat
    @AppStorage(AppConstants.analyticsAutoRunKey) private var autoRunAfterConversion = false

    @State private var enabledMetrics: Set<String> = []

    var body: some View {
        Form {
            metricsSection
            vmafSettingsSection
            exportSection
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

    // MARK: - Export Section

    private var exportSection: some View {
        Section(header: Text("Export")) {
            Picker("Export Format", selection: $exportFormat) {
                ForEach(AnalyticsExportFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format.rawValue)
                }
            }
        }
    }

    // MARK: - Automation Section

    private var automationSection: some View {
        Section(header: Text("Automation")) {
            Toggle("Automatically run analytics after conversion", isOn: $autoRunAfterConversion)
            Text("When enabled, quality analytics will run on each file immediately after encoding completes.")
                .font(.caption)
                .foregroundColor(.secondary)
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
                    name: "SSIMULACRA2",
                    detail: "Perceptual quality metric by Cloudflare. Measures structural similarity on a 0-100 scale. Scores above 70 indicate good quality."
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
