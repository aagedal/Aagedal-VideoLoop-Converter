// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct TesseractSettingsView: View {
    @State private var tesseractVersion: String? = nil
    @State private var isCheckingStatus = true
    @State private var availableLanguages: [String] = []
    @State private var visionLanguages: [String] = []

    @AppStorage(AppConstants.ocrEngineKey)             private var engineRaw = AppConstants.defaultOCREngine
    @AppStorage(AppConstants.tesseractBinarySourceKey) private var binarySource = BinarySourceSelection.app.rawValue
    @AppStorage(AppConstants.tesseractCustomPathKey)   private var customPath = ""
    @AppStorage(AppConstants.tesseractLanguageKey)     private var selectedLanguage = AppConstants.defaultTesseractLanguage
    @AppStorage(AppConstants.visionLanguageKey)        private var selectedVisionLanguage = AppConstants.defaultVisionLanguage

    private var selectedEngine: OCREngineKind {
        OCREngineKind(rawValue: engineRaw) ?? .tesseract
    }

    private var selectedSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: binarySource) ?? .app
    }

    var body: some View {
        Form {
            engineSection
            if selectedEngine == .tesseract {
                statusSection
                binarySourceSection
                tesseractLanguageSection
                tessdataSection
            } else {
                visionLanguageSection
            }
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
        .onChange(of: engineRaw) { _, _ in
            Task { await loadState() }
        }
    }

    // MARK: - Engine Section

    private var engineSection: some View {
        Section(header: Text("OCR Engine")) {
            Picker("Engine", selection: $engineRaw) {
                ForEach(OCREngineKind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedEngine == .tesseract
                 ? "Tesseract is bundled with the app and works offline. Quality varies on stylised fonts."
                 : "Apple Vision uses macOS's built-in text recognizer — no extra downloads, often higher quality, but limited to languages Vision supports.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Status Section (Tesseract)

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

    // MARK: - Binary Source Section (Tesseract)

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
                    .pickerStyle(.menu)
                    .labelsHidden()
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

    // MARK: - Language Section (Tesseract)

    private var tesseractLanguageSection: some View {
        Section(header: Text("Recognition Language")) {
            VStack(alignment: .leading, spacing: 8) {
                if availableLanguages.isEmpty {
                    Text("No tessdata found. Bundle eng.traineddata in Resources/tessdata/ or add it to the tessdata folder below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(availableLanguages, id: \.self) { lang in
                            Text(tesseractLanguageDisplayName(lang)).tag(lang)
                        }
                    }
                }
                Text("The language must match the subtitle language. More .traineddata files can be added to the tessdata folder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Language Section (Vision)

    private var visionLanguageSection: some View {
        Section(header: Text("Recognition Language")) {
            VStack(alignment: .leading, spacing: 8) {
                if visionLanguages.isEmpty {
                    Text("Vision did not report any supported languages on this system.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Language", selection: $selectedVisionLanguage) {
                        ForEach(visionLanguages, id: \.self) { lang in
                            Text(visionLanguageDisplayName(lang)).tag(lang)
                        }
                    }
                }
                Text("Auto-detected subtitle stream language overrides this when present in the source file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Tessdata Section (Tesseract)

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
                if selectedEngine == .tesseract {
                    Text("Accuracy is typically 99%+ for commercial Blu-ray titles with clean, high-contrast subtitle images. Stylised fonts, coloured text, or non-Latin scripts may reduce accuracy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Tesseract OCR is open source and licensed under the Apache 2.0 License.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Apple Vision is part of macOS and runs locally on the GPU. It often produces cleaner output than Tesseract for printed Latin-script text and supports several non-Latin scripts as well.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadState() async {
        await MainActor.run { isCheckingStatus = true }
        let version = await BinaryPathResolver.getTesseractVersion()
        let langs = loadAvailableLanguages()
        let visionLangs = VisionOCREngine.supportedLanguages()
        await MainActor.run {
            tesseractVersion = version
            availableLanguages = langs
            visionLanguages = visionLangs
            isCheckingStatus = false
            // Ensure selected Tesseract language is still valid
            if !langs.isEmpty && !langs.contains(selectedLanguage) {
                selectedLanguage = langs.first ?? AppConstants.defaultTesseractLanguage
            }
            // Ensure selected Vision language is still valid
            if !visionLangs.isEmpty && !visionLangs.contains(selectedVisionLanguage) {
                selectedVisionLanguage = visionLangs.contains(AppConstants.defaultVisionLanguage)
                    ? AppConstants.defaultVisionLanguage
                    : (visionLangs.first ?? AppConstants.defaultVisionLanguage)
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

    private func tesseractLanguageDisplayName(_ code: String) -> String {
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

    private func visionLanguageDisplayName(_ bcp47: String) -> String {
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: bcp47), !name.isEmpty {
            return "\(name) (\(bcp47))"
        }
        return bcp47
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
