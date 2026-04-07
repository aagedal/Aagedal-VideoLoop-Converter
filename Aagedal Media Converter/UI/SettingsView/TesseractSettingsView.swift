// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct TesseractSettingsView: View {
    @State private var tesseractVersion: String? = nil
    @State private var isCheckingStatus = true
    @State private var availableLanguages: [String] = []

    @AppStorage(AppConstants.tesseractBinarySourceKey) private var binarySource = BinarySourceSelection.app.rawValue
    @AppStorage(AppConstants.tesseractCustomPathKey)   private var customPath = ""
    @AppStorage(AppConstants.tesseractLanguageKey)     private var selectedLanguage = AppConstants.defaultTesseractLanguage

    private var selectedSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: binarySource) ?? .app
    }

    var body: some View {
        Form {
            statusSection
            binarySourceSection
            languageSection
            tessdataSection
            aboutSection
        }
        .formStyle(.grouped)
        .task {
            await loadState()
        }
        .onChange(of: binarySource) { _, _ in
            Task { await loadState() }
        }
        .onChange(of: customPath) { _, _ in
            Task { await loadState() }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section(header: Text("Tesseract OCR (Subtitle Conversion)")) {
            HStack {
                if isCheckingStatus {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking…")
                        .font(.headline)
                        .foregroundColor(.secondary)
                } else if let version = tesseractVersion {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Ready")
                        .font(.headline)
                    Spacer()
                    Text(version)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Tesseract not found")
                        .font(.headline)
                    Spacer()
                    if selectedSource == .app {
                        Text("Bundle the tesseract binary in Binaries/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedSource == .homebrew {
                        Text("brew install tesseract")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if tesseractVersion == nil && !isCheckingStatus {
                Text("Tesseract is required for OCR subtitle conversion. Install via Homebrew or bundle the binary with the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Binary Source Section

    private var binarySourceSection: some View {
        Section(header: Text("Binary Source")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Source:")
                        .frame(width: 60, alignment: .trailing)
                    Picker("Source", selection: $binarySource) {
                        Text("App (Bundled)").tag(BinarySourceSelection.app.rawValue)
                        Text("Homebrew").tag(BinarySourceSelection.homebrew.rawValue)
                        Text("Custom").tag(BinarySourceSelection.custom.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Spacer()
                }

                if selectedSource == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom tesseract path:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Select tesseract binary", text: $customPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Button("Browse…") {
                                selectBinary()
                            }

                            if !customPath.isEmpty {
                                Button(role: .destructive) {
                                    customPath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if let resolvedPath = BinaryPathResolver.tesseractPath {
                    Text("Resolved: \(resolvedPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        Section(header: Text("Recognition Language")) {
            VStack(alignment: .leading, spacing: 8) {
                if availableLanguages.isEmpty {
                    Text("No tessdata found. Bundle eng.traineddata in Resources/tessdata/ or add it to the tessdata folder below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(availableLanguages, id: \.self) { lang in
                            Text(languageDisplayName(lang)).tag(lang)
                        }
                    }
                }
                Text("The language must match the subtitle language. More .traineddata files can be added to the tessdata folder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Tessdata Section

    private var tessdataSection: some View {
        Section(header: Text("Tessdata Folder")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add extra language files (.traineddata) for Tesseract here:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text(AppConstants.tesseractTessdataDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(AppConstants.tesseractTessdataDirectory)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("OCR converts picture-based subtitles (Blu-ray PGS, DVD VOBSUB) to SRT text. It reads the original subtitle images from the source file — no audio processing required.")
                    .font(.caption)
                Text("Accuracy is typically 99%+ for commercial Blu-ray titles with clean, high-contrast subtitle images. Stylised fonts, coloured text, or non-Latin scripts may reduce accuracy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Tesseract OCR is open source and licensed under the Apache 2.0 License.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func loadState() async {
        await MainActor.run { isCheckingStatus = true }
        let version = await BinaryPathResolver.getTesseractVersion()
        let langs = loadAvailableLanguages()
        await MainActor.run {
            tesseractVersion = version
            availableLanguages = langs
            isCheckingStatus = false
            // Ensure selected language is still valid
            if !langs.isEmpty && !langs.contains(selectedLanguage) {
                selectedLanguage = langs.first ?? AppConstants.defaultTesseractLanguage
            }
        }
    }

    private func loadAvailableLanguages() -> [String] {
        var languages: [String] = []

        let searchPaths: [String] = [
            AppConstants.tesseractTessdataDirectory.path,
            Bundle.main.path(forResource: "tessdata", ofType: nil) ?? "",
            "/opt/homebrew/share/tessdata",
            "/usr/local/share/tessdata",
        ]

        for dir in searchPaths where !dir.isEmpty {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let langs = files.filter { $0.hasSuffix(".traineddata") }
                             .map { $0.replacingOccurrences(of: ".traineddata", with: "") }
            for lang in langs where !languages.contains(lang) {
                languages.append(lang)
            }
        }

        return languages.sorted()
    }

    private func languageDisplayName(_ code: String) -> String {
        // Map common tessdata codes to human-readable names
        let names: [String: String] = [
            "eng": "English",
            "nor": "Norwegian",
            "nob": "Norwegian Bokmål",
            "dan": "Danish",
            "swe": "Swedish",
            "deu": "German",
            "fra": "French",
            "spa": "Spanish",
            "ita": "Italian",
            "jpn": "Japanese",
            "chi_sim": "Chinese (Simplified)",
            "chi_tra": "Chinese (Traditional)",
            "kor": "Korean",
            "por": "Portuguese",
            "rus": "Russian",
            "ara": "Arabic",
            "nld": "Dutch",
            "fin": "Finnish",
            "pol": "Polish",
            "ces": "Czech",
            "hun": "Hungarian",
            "osd": "OSD — Orientation & Script Detection (not for text recognition)",
            "snum": "Script/Number detection (not for text recognition)",
        ]
        return names[code] ?? code.uppercased()
    }

    private func selectBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Tesseract Binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }
}

#Preview {
    TesseractSettingsView()
}
