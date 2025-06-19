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

    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>, outputFolder: String
    ) {
        Task {
            guard !self.isConverting else { return }

            self.isConverting = true
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder)
        }
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>, outputFolder: String
    ) {
        Task {
            guard
                let nextFileIndex = droppedFiles.wrappedValue.firstIndex(where: {
                    $0.status == .waiting
                })
            else {
                self.isConverting = false
                return
            }

            droppedFiles.wrappedValue[nextFileIndex].status = .converting

            let inputURL = droppedFiles.wrappedValue[nextFileIndex].url
            let outputURL = URL(fileURLWithPath: "\(outputFolder)/\(inputURL.lastPathComponent)")

            await FFMPEGConverter.convert(
                inputURL: inputURL, outputURL: outputURL,
                progressUpdate: { progress, eta in
                    Task { @MainActor in
                        droppedFiles.wrappedValue[nextFileIndex].progress = progress
                        droppedFiles.wrappedValue[nextFileIndex].eta = eta
                    }
                }
            ) { success in
                Task { @MainActor in
                    droppedFiles.wrappedValue[nextFileIndex].status = success ? .done : .failed
                    droppedFiles.wrappedValue[nextFileIndex].progress = 1.0
                    await self.convertNextFile(
                        droppedFiles: droppedFiles, outputFolder: outputFolder)
                }
            }
        }
    }

    func cancelAllConversions() {
        Task {
            currentProcess?.terminate()
            isConverting = false
            currentProcess = nil
        }
    }

    func cancelConversion() {
        Task {
            currentProcess?.terminate()
            currentProcess = nil
        }
    }
}
