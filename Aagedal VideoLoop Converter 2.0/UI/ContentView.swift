//
//  ContentView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.

import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var droppedFiles: [VideoItem] = []
    @State private var currentOutputFolder: URL? = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.appendingPathComponent("VideoLoopExports")
    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
    @State private var selectedPreset: ExportPreset = .videoLoop
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        AppConstants.supportedVideoTypes.compactMap { UTType($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // File list with drag and drop support
            VideoFileListView(
                droppedFiles: $droppedFiles,
                currentProgress: $overallProgress,
                onFileImport: { isFileImporterPresented = true },
                onDoubleClick: { isFileImporterPresented = true },
                onDelete: { indexSet in
                    droppedFiles.remove(atOffsets: indexSet)
                },
                onReset: { index in
                    if index < droppedFiles.count {
                        droppedFiles[index].status = .waiting
                    }
                }
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result: result)
            }
            .toolbar(content: {
                // Main toolbar content
                ToolbarItem(placement: .automatic) {
                    HStack {
                        // Import button
                        Button(action: { isFileImporterPresented = true }) {
                            Label("Import", systemImage: "plus.circle")
                                .foregroundColor(.accentColor)
                        }
                        .help("Import video files")
                        .keyboardShortcut("i", modifiers: .command)
                        
                        // Output folder button
                        Button {
                            Task {
                                if let url = await selectOutputFolder() {
                                    currentOutputFolder = url
                                }
                            }
                        } label: {
                            Label("Output", systemImage: "folder")
                                .foregroundColor(.accentColor)
                        }
                        .help("Select output folder")
                        .keyboardShortcut("o", modifiers: .command)
                        
                        Spacer()
                        
                        // Preset Picker
                        Picker("Preset", selection: $selectedPreset) {
                            ForEach(ExportPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .disabled(isConverting)
                        .foregroundColor(.primary)
                        
                        // Convert/Cancel Button
                        Button {
                            Task {
                                let converting = await ConversionManager.shared.isConvertingStatus()
                                isConverting = converting
                                if converting {
                                    await ConversionManager.shared.cancelConversion()
                                    isConverting = false
                                } else {
                                    await ConversionManager.shared.startConversion(
                                        droppedFiles: $droppedFiles,
                                        outputFolder: currentOutputFolder?.path() ?? "/Users/\(NSUserName())/Downloads/",
                                        preset: selectedPreset
                                    )
                                }
                            }
                        } label: {
                            if isConverting {
                                Text("Cancel")
                                    .foregroundColor(.red)
                            } else {
                                Text("Convert")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(droppedFiles.isEmpty || isConverting)
                    }
                }
            })
            
            // Overall progress bar
            if isConverting {
                VStack(alignment: .leading) {
                    Text("Overall Progress: \(Int(overallProgress * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ProgressView(value: overallProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            Task {
                isConverting = await ConversionManager.shared.isConvertingStatus()
            }
        }
    }

    // Helper function for folder selection
    @MainActor
    private func selectOutputFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        
        if response == .OK {
            return panel.url
        }
        return nil
    }
    
    // Handle file selection from file picker
    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    if let videoItem = await VideoFileUtils.createVideoItem(from: url) {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            droppedFiles.append(videoItem)
                            updateOverallProgress()
                        }
                    } else {
                        print("Skipping unsupported file: \(url.lastPathComponent)")
                    }
                }
            }
        case .failure(let error):
            print("Error selecting files: \(error.localizedDescription)")
        }
    }
    
    private func updateOverallProgress() {
        guard !droppedFiles.isEmpty else {
            overallProgress = 0.0
            return
        }
        
        let totalProgress = droppedFiles.reduce(0.0) { $0 + $1.progress }
        overallProgress = totalProgress / Double(droppedFiles.count)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 800, height: 600)
    }
}
