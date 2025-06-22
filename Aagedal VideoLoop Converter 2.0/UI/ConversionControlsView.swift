//
//  ConversionControlsView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created on 20/06/2024.
//

import SwiftUI

struct ConversionControlsView: View {
    @Binding var isConverting: Bool
    @Binding var droppedFiles: [VideoItem]
    @AppStorage("outputFolder") private var outputFolder: String = AppConstants.defaultOutputDirectory.path
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var showFolderPicker = false
    
    private var currentOutputURL: URL {
        URL(fileURLWithPath: outputFolder)
    }
    
    var body: some View {
        HStack {
            // Preset Picker
            Picker("Preset", selection: $selectedPreset) {
                ForEach(ExportPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(isConverting)
            
            Spacer()
            
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
                            outputFolder: outputFolder,
                            preset: selectedPreset
                        )
                        isConverting = false
                    }
                }
            } label: {
                Label(
                    isConverting ? "✖︎ Cancel" : "▶︎ Start Converting",
                    systemImage: isConverting ? "stop.circle" : "play.circle"
                )
                .padding()
                .buttonStyle(.accessoryBar)
                .tint(isConverting ? .red : .green)
                .cornerRadius(10)
            }
            .keyboardShortcut(.return, modifiers: .command)
            
            Spacer()
            
            // Output Folder Button
            Button {
                showFolderPicker = true
            } label: {
                Label("Output Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(isConverting)
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        outputFolder = url.path(percentEncoded: false)
                    }
                case .failure(let error):
                    print("Error selecting folder: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // Current output folder display name
    private var outputFolderDisplayName: String {
        let url = URL(fileURLWithPath: outputFolder)
        return url.lastPathComponent
    }
}

#Preview {
    ConversionControlsView(
        isConverting: .constant(false),
        droppedFiles: .constant([])
    )
        .frame(width: 600, height: 100)
}
