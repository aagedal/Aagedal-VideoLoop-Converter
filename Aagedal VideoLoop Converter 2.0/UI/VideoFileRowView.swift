import SwiftUI
import AVFoundation

struct VideoFileRowView: View {
    let file: VideoItem
    let preset: ExportPreset
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    
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
                        Text("→")
                        Text(generateOutputFilename(from: file.name))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
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
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text("Size: \(file.size / 1024) KB")
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
                                    Image(systemName: "trash")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(file.status == .converting) // Disable delete during conversion
                                .help(file.status == .converting ? "Cannot delete while converting" : "Delete from list")
                            }
                            
                            // Reset button
                            Button(action: onReset) {
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Reset conversion")
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
