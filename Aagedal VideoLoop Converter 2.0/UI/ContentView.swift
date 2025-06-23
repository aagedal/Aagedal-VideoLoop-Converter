//
//  ContentView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.

import SwiftUI
import AVFoundation
import AppKit

struct ContentView: View {
    @State private var droppedFiles: [VideoItem] = []
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path {
        didSet {
            // Update the currentOutputFolder when outputFolder changes
            currentOutputFolder = URL(fileURLWithPath: outputFolder)
        }
    }
    @State private var currentOutputFolder: URL = AppConstants.defaultOutputDirectory {
        didSet {
            // Update the stored path when currentOutputFolder changes programmatically
            if currentOutputFolder.path != outputFolder {
                outputFolder = currentOutputFolder.path
            }
        }
    }
    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var dockProgressUpdater = DockProgressUpdater()
    @State private var progressTask: Task<Void, Never>?
    
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
                },
                preset: selectedPreset
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result: result)
            }
            .task {
                await startProgressUpdates()
            }
            .toolbar {
                // Convert/Cancel Button
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { @MainActor in
                            // Determine current conversion state from manager to stay in sync
                            let currentlyConverting = await ConversionManager.shared.isConvertingStatus()
                            isConverting = currentlyConverting
                            if currentlyConverting {
                                // Cancel ongoing conversions
                                await cancelConversion()
                            } else {
                                // Start new conversions
                                await startConversion()
                            }
                        }
                    } label: {
                        if isConverting {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "play.circle")
                                .foregroundStyle(droppedFiles.isEmpty ? .gray : .green)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(droppedFiles.isEmpty)
                    .help(droppedFiles.isEmpty ? 
                          "Add files to begin conversion" : 
                          (isConverting ? "Cancel all conversions" : "Start converting all files"))
                }
                
                
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
                            if let folder = await selectOutputFolder() {
                                // This will trigger the didSet on currentOutputFolder
                                // which will update the @AppStorage value
                                currentOutputFolder = folder
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
                        // Only allow clearing if not currently converting
                        guard !isConverting else { return }
                        droppedFiles.removeAll()
                        overallProgress = 0.0
                        // Ensure dock progress is reset when clearing the list
                        dockProgressUpdater.reset()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle((droppedFiles.isEmpty || isConverting) ? Color.gray : Color.red)
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
                    .help("Select export preset for all files.")
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
        }.frame(minWidth: 500, minHeight: 300)
    }

    // Helper function for folder selection
    @MainActor
    private func selectOutputFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        // Set the starting directory to the current output folder if it exists
        if FileManager.default.fileExists(atPath: currentOutputFolder.path) {
            panel.directoryURL = currentOutputFolder
        }
        
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        
        if response == .OK, let url = panel.url {
            // Ensure the directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return nil
    }
    
    // Handle file selection from file picker
    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    if let videoItem = await VideoFileUtils.createVideoItem(
                        from: url,
                        outputFolder: outputFolder,
                        preset: selectedPreset
                    ) {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            droppedFiles.append(videoItem)
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
    
    private func startProgressUpdates() async {
        progressTask?.cancel()
        progressTask = Task {
            for await progress in await ConversionManager.shared.progressUpdates() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    overallProgress = progress
                    dockProgressUpdater.updateProgress(progress)
                    // Automatically reset converting state when done
                    if progress >= 1.0 {
                        isConverting = false
                    }
                }
            }
        }
    }
    
    private func startConversion() async {
        isConverting = true
        // Initialize dock progress with 0% to show it immediately
        dockProgressUpdater.updateProgress(0.0)

        await ConversionManager.shared.startConversion(
                droppedFiles: $droppedFiles,
                outputFolder: currentOutputFolder.path,
                preset: selectedPreset
            )
        

    }
    
    private func cancelConversion() async {
        await ConversionManager.shared.cancelAllConversions()
        isConverting = false
        // Reset dock progress immediately on cancel
        dockProgressUpdater.reset()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(minWidth: 800, minHeight: 400)
    }
}
