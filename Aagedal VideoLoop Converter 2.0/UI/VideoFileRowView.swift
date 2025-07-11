// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVFoundation
import AppKit

struct VideoFileRowView: View {
    let file: VideoItem
    let preset: ExportPreset
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    
    // Show yellow warning icon when VideoLoop preset is used on clips longer than 15 s
    private var showDurationWarning: Bool {
        (preset == .videoLoop || preset == .videoLoopWithAudio) && file.durationSeconds > 15
    }
    
    var body: some View {
        ZStack {
            Rectangle()
                .opacity(0.4)
                .foregroundColor(.indigo)
                .cornerRadius(8)
                .shadow(radius: 8)
            
            HStack {
                // Thumbnail
                ZStack {
                    Rectangle()
                        .frame(width: 100, height: 100)
                        .cornerRadius(9)
                        .foregroundColor(.black)
                        .padding(2)
                    
                    if let data = file.thumbnailData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "film")
                            .padding()
                            .font(.largeTitle)
                    }
                }
                .padding(.leading)
                
                // File info
                VStack(alignment: .leading, spacing: 4) {
                    // Input and output file names
                    HStack {
                        Text(file.name)
                            .font(.headline)
                        // Duration warning icon
                        Text("→")
                        HStack(spacing: 4) {
                            Text(generateOutputFilename(from: file.name))
                                .font(.headline)
                                .foregroundColor((file.status == .waiting && file.outputFileExists) ? .orange : .primary)
                            
                            if file.status == .waiting && file.outputFileExists, let outputURL = file.outputURL {
                                Button(action: {
                                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                }) {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(.orange)
                                        .help("Output file already exists. Click to show in Finder")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            
                            if file.status == .done, let outputURL = file.outputURL {
                                Button(action: {
                                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                }) {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(.blue)
                                        .help("Show in Finder")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                        Spacer()
                    }
                    
                    // Progress and status
                    if file.status == .converting {
                        ProgressView(value: file.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                    }
                    
                    // Metadata
                    HStack {
                        Text("Duration: \(file.duration)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        if showDurationWarning {
                            Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                                .foregroundColor(.yellow)
                                .help("Duration exceeds 15 seconds. VideoLoops are best suited for shorter videos.")
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text("Input Size: \(file.formattedSize)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        Spacer()
                        
                        // Status
                        Text(progressText)
                            .font(.subheadline)
                            .foregroundColor(statusColor)
                        
                        // Action buttons
                        HStack(spacing: 8) {
                            // Cancel/Delete button
                            if file.status == .converting {
                                Button(action: onCancel) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .help("Cancel conversion")
                            } else {
                                Button(action: onDelete) {
                                    Image(systemName: "delete.backward")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(file.status == .converting) // Disable delete during conversion
                                .help(file.status == .converting ? "Cannot delete while converting" : "Delete from list")
                            }
                            
                            // Reset button
                            Button(action: onReset) {
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundStyle(file.status == .converting || file.status == .waiting ? .gray : .blue)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Reset conversion")
                            .disabled(file.status == .converting || file.status == .waiting)
                        }
                    }
                }
                .padding()
            }
        }
    }
    
    private var progressText: String {
        switch file.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = file.eta {
                return "Converting... ETA: \(eta)"
            } else {
                return "Converting..."
            }
        case .done:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
    
    private var statusColor: Color {
        switch file.status {
        case .done: return .green
        case .converting: return .blue
        case .cancelled: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
    
    private func generateOutputFilename(from input: String) -> String {
        let filename = (input as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(filename)
        return "\(sanitized)\(preset.fileSuffix).\(preset.fileExtension)"
    }
}

struct VideoFileRowView_Previews: PreviewProvider {
    static var previews: some View {
        let item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video.mp4"),
            name: "Sample Video",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: nil
        )
        
        return VideoFileRowView(
            file: item,
            preset: .videoLoop,
            onCancel: {},
            onDelete: {},
            onReset: {}
        )
        .frame(width: 800, height: 120)
        .padding()
    }
}


struct VideoFileRowView_Previews2: PreviewProvider {
    static var previews: some View {
        let item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video2.mp4"),
            name: "Sample Video 2",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .converting,
            progress: 0.3,
            eta: nil,
            outputURL: nil
        )
        
        return VideoFileRowView(
            file: item,
            preset: .videoLoop,
            onCancel: {},
            onDelete: {},
            onReset: {}
        )
        .frame(width: 800, height: 120)
        .padding()
    }
}
