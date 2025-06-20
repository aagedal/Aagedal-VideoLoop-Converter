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
        droppedFiles: Binding<[VideoItem]>, outputFolder: String
    ) async {
        guard !self.isConverting else { return }
        self.isConverting = true
        await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder)
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>, outputFolder: String
    ) async {
        guard let nextFile = droppedFiles.wrappedValue.first(where: { $0.status == .waiting }) else {
            self.isConverting = false
            return
        }
        let fileId = nextFile.id
        if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
            droppedFiles.wrappedValue[idx].status = .converting
        }
        let inputURL = nextFile.url
        let outputURL = URL(fileURLWithPath: "\(outputFolder)/\(inputURL.lastPathComponent)")

        await ffmpegConverter.convert(
            inputURL: inputURL, outputURL: outputURL,
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
                    droppedFiles.wrappedValue[idx].progress = 1.0
                }
                await self.convertNextFile(
                    droppedFiles: droppedFiles, outputFolder: outputFolder)
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
