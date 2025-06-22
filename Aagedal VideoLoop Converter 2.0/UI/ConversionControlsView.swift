//
//  ConversionControlsView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created on 20/06/2024.
//

import SwiftUI

struct ConversionControlsView: View {
    @Binding var isConverting: Bool
    @Binding var currentOutputFolder: URL?
    @Binding var droppedFiles: [VideoItem]
    @State private var selectedPreset: ExportPreset = .videoLoop
    
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
                            outputFolder: currentOutputFolder?.path() ?? "/Users/user/Downloads/",
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
                Task {
                    if let url = await selectOutputFolder() {
                        currentOutputFolder = url
                    }
                }
            } label: {
                Label("Output Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(isConverting)
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

#Preview {
    ConversionControlsView(
        isConverting: .constant(false),
        currentOutputFolder: .constant(URL(fileURLWithPath: "/")),
        droppedFiles: .constant([])
    )
}
