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
            .toolbar {
                // Import button
                ToolbarItem(placement: .automatic) {
                    Button(action: { isFileImporterPresented = true }) {
                        Label("Import", systemImage: "plus.circle")
                            .foregroundColor(.accentColor)
                    }
                    .help("Import video files")
                    .keyboardShortcut("i", modifiers: .command)
                }
                
                // Output folder button
                ToolbarItem(placement: .automatic) {
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
                }
                
                // Spacer to push remaining items to the right
                ToolbarItem(placement: .automatic) {
                    Spacer()
                }
                
                // Clear List button
                ToolbarItem(placement: .automatic) {
                    Button {
                        droppedFiles.removeAll()
                        overallProgress = 0.0
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .help("Remove all files from the list")
                    .disabled(droppedFiles.isEmpty || isConverting)
                }
                
                // Preset Picker
                ToolbarItem(placement: .automatic) {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .disabled(isConverting)
                    .foregroundColor(.primary)
                }
                
                // Convert/Cancel Button
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            let converting = await ConversionManager.shared.isConvertingStatus()
                            isConverting = converting
                            if converting {
                                await ConversionManager.shared.cancelConversion()
                                isConverting = false
                            } else {
                                isConverting = true
                                await ConversionManager.shared.startConversion(
                                    droppedFiles: $droppedFiles,
                                    outputFolder: currentOutputFolder?.path() ?? "/Users/user/Downloads/",
                                    preset: selectedPreset
                                )
                                isConverting = false
                            }
                        }
                    } label: {
                        if isConverting {
                            Image(systemName: "cross.circle").foregroundStyle(.red)
                            Text("Cancel")
                                .foregroundColor(.red)
                        } else {
                            Image(systemName: "play.circle").foregroundStyle(.green)
                            Text("Convert")
                                .foregroundColor(.green)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(droppedFiles.isEmpty || isConverting)
                }
                
                // Cancel All button - only show when converting
                if isConverting {
                    ToolbarItem(placement: .automatic) {
                        Button(action: {
                            Task {
                                await cancelAllConversions()
                            }
                        }) {
                            Label("Cancel All", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                        }
                        .help("Cancel all conversions")
                    }
                }
            }
            
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
    
    private func cancelAllConversions() async {
        await ConversionManager.shared.cancelAllConversions()
        // Update the UI to reflect the cancellation
        for index in droppedFiles.indices where droppedFiles[index].status == .converting {
            droppedFiles[index].status = .failed
            droppedFiles[index].progress = 0.0
        }
        isConverting = false
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 800, height: 600)
    }
}
