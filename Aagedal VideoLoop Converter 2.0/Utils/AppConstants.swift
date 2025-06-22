//
//  AppConstants.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created on 20/06/2024.
//

import Foundation

enum AppConstants {
    // Default output directory
    static let defaultOutputDirectory: URL = {
        let defaultDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoLoopExports")
        
        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        return defaultDir
    }()
    
    // Supported video file extensions (lowercase)
    static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "flv", "wmv", "mxf"]
    
    // Supported UTType identifiers for file picker
    static let supportedVideoTypes: [String] = [
        "public.movie",
        "public.video",
        "public.mpeg-4",
        "com.apple.quicktime-movie",
        "com.apple.m4v-video",
        "public.avi",
        "com.apple.m4v-video",
        "public.mpeg-4-audio"
    ]
    
    // Maximum thumbnail dimensions
    static let maxThumbnailSize = CGSize(width: 320, height: 320)
}
