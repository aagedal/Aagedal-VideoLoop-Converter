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
        case cancelled
    }
    

    private var isConverting = false
    private var currentProcess: Process?
    private var ffmpegConverter = FFMPEGConverter()
    private var conversionQueue: [VideoItem] = []
    private var currentDroppedFiles: Binding<[VideoItem]>?
    private var currentOutputFolder: String?
    private var currentPreset: ExportPreset = .videoLoop
    
    // Progress tracking with Swift Concurrency
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var progressStream: AsyncStream<Double>?
    // Periodic task that yields overall progress every few seconds while converting
    private var progressTimerTask: Task<Void, Never>?
    
    func progressUpdates() -> AsyncStream<Double> {
        let stream = AsyncStream(Double.self) { continuation in
            // Store the continuation directly without using a weak self capture
            // since we're not mutating any actor state here
            let task = Task {
                self.setProgressContinuation(continuation)
            }
            
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.clearProgressContinuation()
                }
            }
        }
        progressStream = stream
        return stream
    }
    
    private func setProgressContinuation(_ continuation: AsyncStream<Double>.Continuation) {
        progressContinuation = continuation
    }
    
    private func clearProgressContinuation() {
        progressContinuation = nil
    }

    // MARK: - Periodic Progress Timer
        /// Starts a periodic task that emits overall progress every 3 s
    private func startProgressTimer(droppedFiles: Binding<[VideoItem]>) {
        progressTimerTask?.cancel()
        
                progressTimerTask = Task { [weak self] in
            guard let self else { return }
            while await self.isConverting {
                await self.updateOverallProgress(droppedFiles: droppedFiles)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }
    
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
        self.currentDroppedFiles = droppedFiles
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset
        progressContinuation?.yield(0.0)
        // Start periodic updates so dock appears immediately
        startProgressTimer(droppedFiles: droppedFiles)
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
        // Update overall progress before starting next file
        await updateOverallProgress(droppedFiles: droppedFiles)
        
        guard let nextFile = droppedFiles.wrappedValue.first(where: { $0.status == .waiting }) else {
            self.isConverting = false
            progressContinuation?.yield(1.0)
            stopProgressTimer()
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
        let sanitizedBaseName = FileNameProcessor.processFileName(inputURL.deletingPathExtension().lastPathComponent)
        let outputFileName = sanitizedBaseName + preset.fileSuffix
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
                
                // Only continue if conversion has not been cancelled
                if await self.isConverting {
                    await self.convertNextFile(
                        droppedFiles: droppedFiles,
                        outputFolder: outputFolder,
                        preset: preset
                    )
                }
            }
        }
    }

    func cancelConversion() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()
        currentProcess = nil
        // Update status to cancelled for all converting items
        for idx in conversionQueue.indices where conversionQueue[idx].status == .converting {
            conversionQueue[idx].status = .cancelled
        }
        stopProgressTimer()
    }
    
    /// Cancels a single video item without aborting the entire queue
    func cancelItem(with id: UUID) async {
        guard let droppedFiles = currentDroppedFiles else { return }
        
        // If the item is currently converting
        if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .converting }) {
            await ffmpegConverter.cancelConversion()
            currentProcess = nil
            droppedFiles.wrappedValue[idx].status = .cancelled
            droppedFiles.wrappedValue[idx].progress = 0.0
            
            // Re-compute progress and continue queue
            await updateOverallProgress(droppedFiles: droppedFiles)
            if isConverting {
                await convertNextFile(droppedFiles: droppedFiles,
                                       outputFolder: currentOutputFolder ?? "",
                                       preset: currentPreset)
            }
            return
        }
        
        // If the item is still waiting, simply mark as cancelled
        if let waitingIdx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .waiting }) {
            droppedFiles.wrappedValue[waitingIdx].status = .cancelled
            await updateOverallProgress(droppedFiles: droppedFiles)
        }
    }
    func cancelAllConversions() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()
        // Clear the conversion queue
        conversionQueue.removeAll()
        isConverting = false
        // Update status to cancelled
        for idx in conversionQueue.indices {
            conversionQueue[idx].status = .cancelled
        }
        progressContinuation?.yield(0.0)
        stopProgressTimer()
    }
    
    private func updateOverallProgress(droppedFiles: Binding<[VideoItem]>) async {
        let files = droppedFiles.wrappedValue
        guard !files.isEmpty else {
            progressContinuation?.yield(0.0)
            return
        }
        
        let totalProgress = files.reduce(0.0) { result, file in
            return result + (file.status == .done ? 1.0 : file.progress)
        }
        
        let progress = min(max(totalProgress / Double(files.count), 0.0), 1.0)
        progressContinuation?.yield(progress)
    }
}
