// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct ParakeetSettingsView: View {
    @State private var installationStatus: ParakeetInstallationStatus = .notInstalled
    @State private var isCheckingStatus = true
    @State private var versionString: String?

    @State private var downloadedModels: [ParakeetModel] = []
    @State private var modelDownloadProgress: [String: Double] = [:]
    @State private var modelDownloading: Set<String> = []
    @State private var deleteError: String?

    @AppStorage(AppConstants.parakeetModelKey) private var selectedModelId = AppConstants.defaultParakeetModel
    @AppStorage(AppConstants.parakeetCustomPathKey) private var customPath = ""
    @AppStorage(AppConstants.parakeetLanguageKey) private var selectedLanguage = AppConstants.defaultParakeetLanguage

    var body: some View {
        Section(header: Text("parakeet-mlx (NeMo ASR on Apple Silicon)")) {
            statusSection
        }

        Section(header: Text("Parakeet Models")) {
            modelManagementSection
        }

        Section(header: Text("Parakeet Default Settings")) {
            defaultSettingsSection
        }

        Section(header: Text("About Parakeet")) {
            aboutSection
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if isCheckingStatus {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Checking...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                } else {
                    switch installationStatus {
                    case .notInstalled:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("parakeet-mlx not installed")
                            .font(.headline)
                    case .installed(let version):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Ready")
                            .font(.headline)
                        Spacer()
                        Text(versionString ?? version)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !installationStatus.isAvailable && !isCheckingStatus {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install parakeet-mlx to enable Parakeet transcription:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("pip:")
                                .font(.caption).bold()
                            Text("pip install -U parakeet-mlx")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("uv:")
                                .font(.caption).bold()
                            Text("uv tool install parakeet-mlx")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("Custom path:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("parakeet-mlx binary path", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button("Browse...") {
                    selectCustomBinary()
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

            if !customPath.isEmpty && !FileManager.default.isExecutableFile(atPath: customPath) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Binary not found at custom path.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .task {
            await loadState()
        }
        .onChange(of: customPath) { _, _ in
            Task { await loadState() }
        }
    }

    // MARK: - Model Management Section

    private var modelManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models are downloaded automatically on first use via HuggingFace Hub. You can also manage cached models here.")
                .font(.callout)
                .foregroundColor(.secondary)

            ForEach(ParakeetModel.allModels) { model in
                modelRow(for: model)
                if model.id != ParakeetModel.allModels.last?.id {
                    Divider()
                }
            }

            if let error = deleteError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if !downloadedModels.isEmpty {
                Divider()

                HStack {
                    Text("Cached models: \(downloadedModels.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(role: .destructive) {
                        deleteAllModels()
                    } label: {
                        Text("Delete All Cached Models")
                    }
                }
            }
        }
        .padding(8)
    }

    private func modelRow(for model: ParakeetModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName)
                        .font(.headline)

                    if selectedModelId == model.id {
                        Text("Selected")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }

                    if model.isMultilingual {
                        Text("Multilingual")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(model.fileSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if modelDownloading.contains(model.id) {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: modelDownloadProgress[model.id] ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                    Text("\(Int((modelDownloadProgress[model.id] ?? 0) * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if downloadedModels.contains(where: { $0.id == model.id }) {
                HStack(spacing: 8) {
                    if selectedModelId != model.id {
                        Button("Select") {
                            selectedModelId = model.id
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive) {
                        deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        downloadModel(model)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!installationStatus.isAvailable)
                }
            }
        }
    }

    // MARK: - Default Settings Section

    private var defaultSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Default model:")
                    .frame(width: 120, alignment: .trailing)

                Picker("", selection: $selectedModelId) {
                    ForEach(ParakeetModel.allModels) { model in
                        Text(model.displayName)
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
            }

            // Show language picker only for multilingual models
            if let model = ParakeetModel.model(for: selectedModelId), model.isMultilingual {
                HStack {
                    Text("Default language:")
                        .frame(width: 120, alignment: .trailing)

                    Picker("", selection: $selectedLanguage) {
                        ForEach(ParakeetLanguage.allCases, id: \.self) { language in
                            Text(language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Text("Specifying a language can improve accuracy. Use 'Auto-detect' for mixed-language content.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("The selected model supports English only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parakeet is NVIDIA's state-of-the-art automatic speech recognition model, optimized for Apple Silicon via the MLX framework. It can produce highly accurate transcriptions with word-level timestamps.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Models are cached in ~/.cache/huggingface/hub/ and downloaded on first use.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link("parakeet-mlx", destination: URL(string: "https://github.com/senstella/parakeet-mlx")!)
                Spacer()
                Link("NVIDIA NeMo", destination: URL(string: "https://github.com/NVIDIA/NeMo")!)
            }
            .font(.callout)
        }
        .padding(8)
    }

    // MARK: - Actions

    private func loadState() async {
        await MainActor.run { isCheckingStatus = true }

        let status = ParakeetService.shared.getInstallationStatus()
        let models = ParakeetModelManager.shared.getDownloadedModels()
        let version = await BinaryPathResolver.getParakeetMlxVersion()

        await MainActor.run {
            installationStatus = status
            downloadedModels = models
            versionString = version
            isCheckingStatus = false
        }
    }

    private func downloadModel(_ model: ParakeetModel) {
        modelDownloading.insert(model.id)
        modelDownloadProgress[model.id] = 0
        deleteError = nil

        Task {
            do {
                try await ParakeetModelManager.shared.downloadModel(model) { progress in
                    Task { @MainActor in
                        modelDownloadProgress[model.id] = progress
                    }
                }
                await MainActor.run {
                    downloadedModels = ParakeetModelManager.shared.getDownloadedModels()
                    modelDownloading.remove(model.id)
                    modelDownloadProgress.removeValue(forKey: model.id)

                    // Auto-select if it's the first model
                    if downloadedModels.count == 1 {
                        selectedModelId = model.id
                    }
                }
            } catch {
                await MainActor.run {
                    modelDownloading.remove(model.id)
                    modelDownloadProgress.removeValue(forKey: model.id)
                    deleteError = "Failed to download \(model.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteModel(_ model: ParakeetModel) {
        Task {
            do {
                try await ParakeetModelManager.shared.deleteModel(model)
                await MainActor.run {
                    downloadedModels = ParakeetModelManager.shared.getDownloadedModels()
                }
            } catch {
                await MainActor.run {
                    deleteError = "Failed to delete \(model.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteAllModels() {
        Task {
            do {
                try await ParakeetModelManager.shared.deleteAllModels()
                await MainActor.run {
                    downloadedModels = []
                }
            } catch {
                await MainActor.run {
                    deleteError = "Failed to delete models: \(error.localizedDescription)"
                }
            }
        }
    }

    private func selectCustomBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Select parakeet-mlx binary"
        panel.message = "Choose the parakeet-mlx executable."
        panel.prompt = "Select"
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }
}

#Preview {
    ParakeetSettingsView()
}
