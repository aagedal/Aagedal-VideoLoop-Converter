//
//  FFMPEGConverter.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created on 20/06/2024.
//

import Foundation

enum ExportPreset: String, CaseIterable, Identifiable {
    case videoLoop = "VideoLoop"
    case videoLoopWithAudio = "VideoLoop w/Audio"
    case tvQuality = "TV Quality"
    case prores = "ProRes"
    case animatedAVIF = "Animated AVIF"
    
    var id: String { self.rawValue }
    
    var fileExtension: String {
        switch self {
        case .videoLoop, .videoLoopWithAudio:
            return "mp4"
        case .tvQuality, .prores:
            return "mov"
        case .animatedAVIF:
            return "avif"
        }
    }
    
    var displayName: String {
        return self.rawValue
    }
    
    var description: String {
        switch self {
        case .videoLoop:
            return "Optimized for seamless video loops without audio. Uses H.264 encoding with high quality settings and no audio track."
        case .videoLoopWithAudio:
            return "Seamless video loops with audio. Uses H.264 encoding with high quality settings and includes the audio track."
        case .tvQuality:
            return "High quality format suitable for TV playback. Uses HEVC (H.265) encoding with 10-bit color depth and PCM audio."
        case .prores:
            return "Professional editing format with high quality. Uses Apple ProRes 422 HQ codec with 10-bit color depth and PCM audio."
        case .animatedAVIF:
            return "Modern, highly efficient image format with animation support. Uses AV1 codec for excellent compression."
        }
    }
    
    var fileSuffix: String {
        switch self {
        case .videoLoop:
            return "_loop"
        case .videoLoopWithAudio:
            return "_loop_audio"
        case .tvQuality:
            return "_tv"    
        case .prores:
            return "_prores"
        case .animatedAVIF:
            return "_avif"
        }
    }
    
    var ffmpegArguments: [String] {
        let commonArgs = [
            "-hide_banner",
            "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
        ]
        
        switch self {
        case .videoLoop:
            return commonArgs + [
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-an"  // No audio  
            ]
            
        case .videoLoopWithAudio:
            return commonArgs + [
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-c:a", "aac",
                "-b:a", "192k"
            ]
            
        case .tvQuality:
            return commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "hevc_videotoolbox",
                "-b:v", "15M",
                "-profile:v", "main10",
                "-c:a", "pcm",
                "-map", "0:a:0"
            ]
            
        case .animatedAVIF:
            return commonArgs + [
                "-pix_fmt", "yuv420p",
                "-vcodec", "libsvtav1",
                "-crf", "28", "-an"
            ]
        case .prores:
            return commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "prores_videotoolbox",
                "-c:a", "pcm",
                "-map", "0:a:0"
            ]
        }
    }
}

actor FFMPEGConverter {
    private var currentProcess: Process?

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - inputURL: The source video file URL
    ///   - outputURL: The destination URL (without extension)
    ///   - preset: The export preset to use
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool)
    func convert(
        inputURL: URL,
        outputURL: URL,
        preset: ExportPreset = .videoLoop,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) async {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            print("FFMPEG binary not found in bundle")
            completion(false)
            return
        }

        // Ensure output directory exists
        let fileManager = FileManager.default
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create output directory: \(error)")
            completion(false)
            return
        }

        // Add file extension based on preset
        let outputFileURL = outputURL.appendingPathExtension(preset.fileExtension)
        
        // Remove existing file if it exists
        if fileManager.fileExists(atPath: outputFileURL.path) {
            do {
                try fileManager.removeItem(at: outputFileURL)
            } catch {
                print("Failed to remove existing file: \(error)")
                completion(false)
                return
            }
        }

        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        // Build FFmpeg arguments
        var arguments = ["-y", "-i", inputURL.path]
        arguments.append(contentsOf: preset.ffmpegArguments)
        arguments.append(outputFileURL.path)
        
        process.arguments = arguments
        
        print("FFmpeg command: \(ffmpegPath) \(arguments.joined(separator: " "))")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // Still need to capture stdout to prevent hanging

        let totalDurationBox = DurationBox()
        let errorReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Process the output through our handler
                let (newTotalDuration, _) = Self.handleFFMPEGOutput(output, totalDuration: totalDurationBox.value, progressUpdate: progressUpdate)
                if let newTotalDuration = newTotalDuration {
                    totalDurationBox.value = newTotalDuration
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = errorReadabilityHandler

        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in
                await self?.setCurrentProcess(nil)
                let success = process.terminationStatus == 0
                completion(success)
            }
        }

        do {
            try process.run()
        } catch {
            print("Failed to run process: \(error)")
            completion(false)
        }
    }

    func cancelConversion() async {
        currentProcess?.terminate()
        await setCurrentProcess(nil)
    }

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
    }

    private class DurationBox: @unchecked Sendable {
        var value: Double? = nil
    }

    private static func handleFFMPEGOutput(_ output: String, totalDuration: Double?, progressUpdate: @escaping @Sendable (Double, String?) -> Void) -> (Double?, (Double, String?)?) {
        print("FFMPEG Output: \(output)")
        var newTotalDuration = totalDuration
        if let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            print("Total Duration: \(duration) seconds")
        }
        var progressTuple: (Double, String?)? = nil
        if let progress = ParsingUtils.parseProgress(from: output, totalDuration: newTotalDuration) {
            Task {
                progressUpdate(progress.0, progress.1)
                print("Progress: \(progress.0 * 100)% ETA: \(progress.1 ?? "N/A")")
            }
            progressTuple = progress
        }
        return (newTotalDuration, progressTuple)
    }
}
