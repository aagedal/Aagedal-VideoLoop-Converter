//
//  FFMPEGConverter.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//
import Foundation

//Todo: Add multiple export presets, but make sure to keep this one. File extension follows the preset, but the default for most presets should be .mp4. Likely formats are the current format with and without audio, which is called VideoLoop

actor FFMPEGConverter {
    private var currentProcess: Process?

    func convert(inputURL: URL, outputURL: URL, progressUpdate: @escaping @Sendable (Double, String?) -> Void, completion: @escaping @Sendable (Bool) -> Void) async {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            print("FFMPEG binary not found in bundle")
            completion(false)
            return
        }

        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-i", inputURL.path,
            "-hide_banner",
            "-vcodec", "libx264",
            "-preset", "veryslow",
            "-crf", "23",
            "-minrate", "3000k",
            "-maxrate", "9000k",
            "-bufsize", "18000k",
            "-profile:v", "main",
            "-level:v", "4.0",
            "-pix_fmt", "yuv420p",
            "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'",
            "-bsf:v", "filter_units=remove_types=6",
            "-fflags", "+bitexact",
            "-write_tmcd", "0",
            "-an",
            "-color_trc", "bt709",
            "-movflags", "+faststart",
            outputURL.path
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let totalDurationBox = DurationBox()
        let outputReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8) {
                print("Raw FFMPEG output: \(output)")
                let (newTotalDuration, _) = Self.handleFFMPEGOutput(output, totalDuration: totalDurationBox.value, progressUpdate: progressUpdate)
                if let newTotalDuration = newTotalDuration {
                    totalDurationBox.value = newTotalDuration
                }
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = outputReadabilityHandler
        errorPipe.fileHandleForReading.readabilityHandler = outputReadabilityHandler

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
