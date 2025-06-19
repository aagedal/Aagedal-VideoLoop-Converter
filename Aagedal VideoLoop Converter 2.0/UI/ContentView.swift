//
//  ContentView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.

import SwiftUI

struct ContentView: View {
    @State private var droppedFiles: [VideoItem] = []
    @State private var currentOutputFolder: URL? = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.appendingPathComponent("VideoLoopExports")
    @State private var isConverting: Bool = false

    var body: some View {
        ZStack {
            DragAndDropView(droppedFiles: $droppedFiles)
                .edgesIgnoringSafeArea(.all)
            VStack {
                HStack {
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
                        Text(isConverting ? "Cancel" : "Start Converting")
                            .padding()
                            .background(isConverting ? Color.red : Color.green)
                            .foregroundColor(.white)
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
                        Text("Select Output Folder")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding()
                }
                VideoFileListView(droppedFiles: $droppedFiles, currentProgress: .constant(0.0))
                    .padding()
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
