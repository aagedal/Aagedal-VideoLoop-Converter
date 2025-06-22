//
//  ConversionManager.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//

import AVFoundation
import Foundation
import SwiftUI

actor ConversionManager: Sendable {
    @MainActor static let shared = ConversionManager()
    private init() {}

    enum ConversionStatus {
        case waiting
        case converting
        case done
        case failed
    }
    

    private var isConverting = false
    private var currentProcess: Process?
    private var ffmpegConverter = FFMPEGConverter()

    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop
    ) async {
        guard !self.isConverting else { return }
        self.isConverting = true
        await convertNextFile(
            droppedFiles: droppedFiles,
            outputFolder: outputFolder,
            preset: preset
        )
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset
    ) async {
        guard let nextFile = droppedFiles.wrappedValue.first(where: { $0.status == .waiting }) else {
            self.isConverting = false
            return
        }
        
        let fileId = nextFile.id
        guard let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) else {
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset)
            return
        }
        
        // Update status to converting
        droppedFiles.wrappedValue[idx].status = .converting
        
        let inputURL = nextFile.url
        let outputFileName = inputURL.deletingPathExtension().lastPathComponent
        let outputURL = URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)

        await ffmpegConverter.convert(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            progressUpdate: { progress, eta in
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                        droppedFiles.wrappedValue[idx].progress = progress
                        droppedFiles.wrappedValue[idx].eta = eta
                    }
                }
            }
        ) { success in
            Task { @MainActor in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                    droppedFiles.wrappedValue[idx].status = success ? .done : .failed
                    droppedFiles.wrappedValue[idx].progress = success ? 1.0 : 0
                    
                    // Update the output URL in the video item
                    if success {
                        let outputFileURL = outputURL.appendingPathExtension(preset.fileExtension)
                        droppedFiles.wrappedValue[idx].outputURL = outputFileURL
                    }
                }
                
                // Process next file if any
                await self.convertNextFile(
                    droppedFiles: droppedFiles,
                    outputFolder: outputFolder,
                    preset: preset
                )
            }
        }
    }

    func cancelAllConversions() async {
        await ffmpegConverter.cancelConversion()
        isConverting = false
        currentProcess = nil
    }

    func cancelConversion() async {
        await ffmpegConverter.cancelConversion()
        currentProcess = nil
    }
}
