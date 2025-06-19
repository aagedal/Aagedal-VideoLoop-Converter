//
//  FFMPEGConverter.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//
import Foundation

class FFMPEGConverter: Sendable {
    private static var currentProcess: Process?

    static func convert(inputURL: URL, outputURL: URL, progressUpdate: @escaping @Sendable (Double, String?) -> Void, completion: @escaping @Sendable (Bool) -> Void) async {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            print("FFMPEG binary not found in bundle")
            completion(false)
            return
        }

        let process = Process()
        currentProcess = process
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

        var totalDuration: Double?

        let outputReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8) {
                handleFFMPEGOutput(output, totalDuration: &totalDuration, progressUpdate: progressUpdate)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = outputReadabilityHandler
        errorPipe.fileHandleForReading.readabilityHandler = outputReadabilityHandler

        process.terminationHandler = { _ in
            currentProcess = nil
            let success = process.terminationStatus == 0
            Task {
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

    static func cancelConversion() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    private static func handleFFMPEGOutput(_ output: String, totalDuration: inout Double?, progressUpdate: @escaping @Sendable (Double, String?) -> Void) {
        print("FFMPEG Output: \(output)")
        if let duration = ParsingUtils.parseDuration(from: output) {
            totalDuration = duration
            print("Total Duration: \(totalDuration!) seconds")
        }
        if let progress = ParsingUtils.parseProgress(from: output, totalDuration: totalDuration) {
            Task {
                progressUpdate(progress.0, progress.1)
                print("Progress: \(progress.0 * 100)% ETA: \(progress.1 ?? "N/A")")
            }
        }
    }
}
