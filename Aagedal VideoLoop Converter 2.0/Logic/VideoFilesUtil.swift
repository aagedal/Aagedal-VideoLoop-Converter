//
//  VideoFilesUtil.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//

import AVFoundation
import Cocoa

struct VideoFileUtils: Sendable {
    static func isVideoFile(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return AppConstants.supportedVideoExtensions.contains(fileExtension)
    }
    
    static func createVideoItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop) async -> VideoItem? {
        guard isVideoFile(url: url) else { return nil }
        
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let asset = AVURLAsset(url: url)
        let cmDuration = try? await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(cmDuration ?? CMTime.zero)
        let durationString = formatDuration(seconds: durationSec)
        let thumbnailData = await getVideoThumbnail(url: url)
        
        // Generate output URL if output folder is provided
        var outputURL: URL? = nil
        if let outputFolder = outputFolder {
            let sanitizedBaseName = FileNameProcessor.processFileName(url.deletingPathExtension().lastPathComponent)
            let outputFileName = sanitizedBaseName + preset.fileSuffix + "." + preset.fileExtension
            outputURL = URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)
        }
        
        return VideoItem(
            url: url,
            name: name,
            size: size,
            duration: durationString,
            durationSeconds: durationSec,
            thumbnailData: thumbnailData,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: outputURL
        )
    }
    // utility to format seconds into hh:mm:ss or mm:ss
    private static func formatDuration(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    @available(macOS 13.0, *)
    static func getVideoDuration(url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        
        do {
            let duration = try await asset.load(.duration)
            let durationTime = CMTimeGetSeconds(duration)
            
            let hours = Int(durationTime) / 3600
            let minutes = (Int(durationTime) % 3600) / 60
            let seconds = Int(durationTime) % 60
            
            if hours > 0 {
                return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%02d:%02d", minutes, seconds)
            }
        } catch {
            print("Error loading video duration: \(error)")
            return "Unknown"
        }
    }
    
    static func getVideoThumbnail(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetImageGenerator = AVAssetImageGenerator(asset: asset)
        assetImageGenerator.appliesPreferredTrackTransform = true
        assetImageGenerator.apertureMode = .cleanAperture
        assetImageGenerator.maximumSize = CGSize(width: 320, height: 180) // Thumbnail size
        
        // Get a more representative timestamp (10% into the video)
        let duration = try? await asset.load(.duration)
        let seconds = min(CMTimeGetSeconds(duration ?? CMTime(seconds: 1, preferredTimescale: 1)) * 0.1, 60)
        let time = CMTime(seconds: max(seconds, 0.5), preferredTimescale: 600) // Minimum 0.5 seconds
        
        do {
            let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                assetImageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                    switch result {
                    case .succeeded where image != nil:
                        continuation.resume(returning: image!)
                    case .failed where error != nil:
                        continuation.resume(throwing: error!)
                    case .cancelled:
                        continuation.resume(throwing: NSError(domain: "com.aagedal.videoloop", code: -1, userInfo: [NSLocalizedDescriptionKey: "Thumbnail generation was cancelled"]))
                    default:
                        continuation.resume(throwing: NSError(domain: "com.aagedal.videoloop", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown error generating thumbnail"]))
                    }
                }
            }
            
            // Convert CGImage to PNG data directly without going through NSImage
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            bitmapRep.size = CGSize(width: cgImage.width, height: cgImage.height)
            
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("Failed to create PNG data from thumbnail")
                return nil
            }
            
            return pngData
            
        } catch {
            print("Error generating thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}

struct VideoItem: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    var url: URL
    var name: String
    var size: Int64
    var duration: String
    var durationSeconds: Double = 0.0
    var thumbnailData: Data?
    var status: ConversionManager.ConversionStatus
    var progress: Double
    var eta: String?
    var outputURL: URL?
    
    /// Human-readable file size string (<1 MB ⇒ KB, 1–600 MB ⇒ MB, ≥600 MB ⇒ GB)
    var formattedSize: String {
        let bytes = Double(size)
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        
        if bytes < mb {
            return String(format: "%.0f KB", bytes / kb)
        } else if bytes < 600 * mb {
            return String(format: "%.1f MB", bytes / mb)
        } else {
            return String(format: "%.1f GB", bytes / gb)
        }
    }
    
    var outputFileExists: Bool {
        guard let outputURL = outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
}
