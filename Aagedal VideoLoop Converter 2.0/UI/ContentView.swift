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
    @State private var isFileImporterPresented = false
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        AppConstants.supportedVideoTypes.compactMap { UTType($0) }
    }

    var body: some View {
        ZStack {
            DragAndDropView(droppedFiles: $droppedFiles)
                .edgesIgnoringSafeArea(.all)
            VStack {
                // Add file selection button
                Button(action: {
                    isFileImporterPresented = true
                }) {
                    Label("Import Video Files", systemImage: "plus.circle.fill")
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: supportedVideoTypes,
                    allowsMultipleSelection: true
                ) { result in
                    handleFileSelection(result: result)
                }
                
                // Drag and drop area
                Text("Or drag and drop video files here")
                    .foregroundColor(.secondary)
                    .padding()
                
                // File list
                VideoFileListView(droppedFiles: $droppedFiles, currentProgress: .constant(0.0))
                    .padding()
                
                HStack {
                    // Todo: Extract this as a subview and relink to logic.
                    
                    //Add overall progress bar here.
                    Button {
                        Task {
                            let converting = await ConversionManager.shared.isConvertingStatus()
                            isConverting = converting
                            if converting {
                                await ConversionManager.shared.cancelConversion()
                                isConverting = false
                            } else {
                                await ConversionManager.shared.startConversion(droppedFiles: $droppedFiles, outputFolder: currentOutputFolder?.path() ?? "/Users/user/Downloads/")
                                isConverting = false
                            }
                        }
                    } label: {
                        Text(isConverting ? "✖︎ Cancel" : "▶︎ Start Converting")
                            .padding()
                            .buttonStyle(.accessoryBar).tint(isConverting ? Color.red : Color.green)
                            .cornerRadius(10)
                    }
                    .padding()
                    Spacer()
                    Button {
                        Task {
                            if let url = await selectOutputFolder() {
                                currentOutputFolder = url
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                        Text("Select Output Folder")
                            .buttonStyle(.automatic).tint(Color.blue)
                            .cornerRadius(10)
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            Task {
                isConverting = await ConversionManager.shared.isConvertingStatus()
            }
        }
    }

    // Helper function for folder selection
    private func selectOutputFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { result in
                continuation.resume(returning: result)
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
                        await MainActor.run {
                            if !droppedFiles.contains(where: { $0.url == url }) {
                                droppedFiles.append(videoItem)
                            }
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
