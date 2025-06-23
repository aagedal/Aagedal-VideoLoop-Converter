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
    case tvQualityHD = "TV Quality HD"
    case tvQuality4K = "TV Quality 4K"
    case prores = "ProRes"
    case animatedAVIF = "Animated AVIF"
    
    var id: String { self.rawValue }
    
    var fileExtension: String {
        switch self {
        case .videoLoop, .videoLoopWithAudio:
            return "mp4"
        case .tvQualityHD, .tvQuality4K, .prores:
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
            return NSLocalizedString("PRESET_VIDEO_LOOP_DESCRIPTION", comment: "Description for VideoLoop preset")
        case .videoLoopWithAudio:
            return NSLocalizedString("PRESET_VIDEO_LOOP_WITH_AUDIO_DESCRIPTION", comment: "Description for VideoLoop with Audio preset")
        case .tvQualityHD:
            return NSLocalizedString("PRESET_TV_QUALITY_HD_DESCRIPTION", comment: "Description for TV Quality HD preset")
        case .tvQuality4K:
            return NSLocalizedString("PRESET_TV_QUALITY_4K_DESCRIPTION", comment: "Description for TV Quality 4K preset")
        case .prores:
            return NSLocalizedString("PRESET_PRORES_DESCRIPTION", comment: "Description for ProRes preset")
        case .animatedAVIF:
            return NSLocalizedString("PRESET_ANIMATED_AVIF_DESCRIPTION", comment: "Description for Animated AVIF preset")
        }
    }
    
    var fileSuffix: String {
        switch self {
        case .videoLoop:
            return "_loop"
        case .videoLoopWithAudio:
            return "_loop_audio"
        case .tvQualityHD:
            return "_tv_hd"
        case .tvQuality4K:
            return "_tv_4k"
        case .prores:
            return "_prores"
        case .animatedAVIF:
            return "_avif"
        }
    }
    
    var ffmpegArguments: [String] {
        let commonArgs = [
            "-hide_banner",
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
                "-an",
                "-vf", "yadif=3,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)',minterpolate=fps=min(60\\,fps)"
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
                "-b:a", "192k",
                "-vf", "yadif=3,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)',minterpolate=fps=min(60\\,fps)"
            ]
            
        case .tvQualityHD:
            return commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "hevc_videotoolbox",
                "-b:v", "18M",
                "-profile:v", "main10",
                "-c:a", "pcm",
                "-map", "0:a",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-vf", "yadif=3,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)',minterpolate=fps=min(60\\,fps)"
            ]
            
        case .tvQuality4K:
            return commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "hevc_videotoolbox",
                "-b:v", "60M",
                "-profile:v", "main10",
                "-c:a", "pcm",
                "-map", "0:a",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-vf", "yadif=3,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),2160,-2)':h='if(lte(iw,ih),-2,2160)',minterpolate=fps=min(60\\,fps)"
            ]
            
        case .animatedAVIF:
            return commonArgs + [
                "-pix_fmt", "yuv420p",
                "-vcodec", "libsvtav1",
                "-crf", "28", "-an",
                "-vf", "yadif=3,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)',minterpolate=fps=min(60\\,fps)"
            ]
        case .prores:
            return commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "prores_videotoolbox",
                "-c:a", "pcm",
                "-map", "0:a",
                "-map_metadata", "0",
                "-map_chapters", "0"
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
