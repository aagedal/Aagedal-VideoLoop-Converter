// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct AnalyticsResultsView: View {
    let results: AnalyticsResults
    var onRunMetrics: (([QualityMetric]) -> Void)?
    @Environment(\.dismiss) var dismiss

    /// Metrics that have not been run yet
    private var missingMetrics: [QualityMetric] {
        let completedMetrics = Set(results.metrics.map(\.metric))
        return QualityMetric.allCases.filter { !completedMetrics.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
                .padding()

            Divider()

            // Score cards
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(results.metrics, id: \.metric) { metric in
                        MetricScoreCard(result: metric)
                    }

                    if !missingMetrics.isEmpty, onRunMetrics != nil {
                        missingMetricsSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer with export and close buttons
            footerSection
                .padding()
        }
        .frame(width: 500, height: 500)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Analytics")
                .font(.title2)
                .fontWeight(.semibold)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Source:")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(results.sourceFileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text("Encoded:")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(results.encodedFileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(results.timestamp, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Missing Metrics

    private var missingMetricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional Metrics")
                .font(.headline)
                .foregroundColor(.secondary)

            ForEach(missingMetrics, id: \.self) { metric in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.displayName)
                            .font(.subheadline)
                        Text(metric.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if metric == .ssimulacra2 && !BinaryPathResolver.isSSIMULACRA2Available {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Run") {
                            dismiss()
                            onRunMetrics?([metric])
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            if missingMetrics.count > 1 {
                let runnableMetrics = missingMetrics.filter { metric in
                    metric != .ssimulacra2 || BinaryPathResolver.isSSIMULACRA2Available
                }
                if runnableMetrics.count > 1 {
                    Button("Run All") {
                        dismiss()
                        onRunMetrics?(runnableMetrics)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Export JSON") {
                exportResults(format: .json)
            }

            Button("Export PDF") {
                exportResults(format: .pdf)
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Export

    private func exportResults(format: AnalyticsExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .json
            ? [.json]
            : [.pdf]
        panel.nameFieldStringValue = "\(results.encodedFileName)_analytics.\(format.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .json:
                try AnalyticsExporter.exportJSON(results: results, to: url)
            case .pdf:
                try AnalyticsExporter.exportPDF(results: results, to: url)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Score Card

struct MetricScoreCard: View {
    let result: MetricResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Metric name and rating
            HStack {
                Text(result.metric.displayName)
                    .font(.headline)
                Spacer()
                Text(result.qualityRating)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(ratingColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ratingColor.opacity(0.15))
                    )
            }

            // Main score
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(result.formattedScore)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(ratingColor)

                if result.metric == .psnr || result.metric == .xpsnr {
                    Text("dB")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }

            // Min/Max range
            if let min = result.min, let max = result.max {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("Min:")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", min))
                    }
                    HStack(spacing: 4) {
                        Text("Max:")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", max))
                    }
                }
                .font(.caption)
            }

            // Channel scores (PSNR)
            if let channels = result.channelScores, !channels.isEmpty {
                HStack(spacing: 16) {
                    ForEach(channels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 4) {
                            Text("\(key):")
                                .foregroundColor(.secondary)
                            Text(String(format: "%.2f dB", value))
                        }
                        .font(.caption)
                    }
                }
            }

            // Scale reference
            Text(scaleDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ratingColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var ratingColor: Color {
        switch result.qualityColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .secondary
        }
    }

    private var scaleDescription: String {
        switch result.metric {
        case .vmaf:
            return "Scale: 0-100. >93 Excellent, >80 Good, >60 Fair, <60 Poor"
        case .psnr:
            return "Scale: dB. >40 Excellent, >30 Good, >20 Fair, <20 Poor"
        case .xpsnr:
            return "Scale: dB. >42 Excellent, >32 Good, >22 Fair, <22 Poor"
        case .ssimulacra2:
            return "Scale: 0-100. >90 Excellent, >70 Good, >50 Fair, <50 Poor"
        }
    }
}

#Preview {
    AnalyticsResultsView(results: AnalyticsResults(
        sourceFileName: "test_source.mov",
        encodedFileName: "test_output.mp4",
        metrics: [
            MetricResult(metric: .vmaf, overallScore: 92.5, min: 78.3, max: 99.1, unit: "score", channelScores: nil),
            MetricResult(metric: .psnr, overallScore: 38.7, min: 25.2, max: 48.9, unit: "dB", channelScores: ["Y": 38.7, "U": 42.3, "V": 43.1]),
            MetricResult(metric: .ssimulacra2, overallScore: 85.2, min: 62.4, max: 97.8, unit: "score", channelScores: nil)
        ],
        timestamp: Date(),
        durationSeconds: 120.0
    ))
}
