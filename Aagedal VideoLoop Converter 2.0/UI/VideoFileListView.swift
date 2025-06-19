//
//  VideoFileListView.swift.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//

import SwiftUI

struct VideoFileListView: View {
    @Binding var droppedFiles: [VideoItem]
    @Binding var currentProgress: Double

    var body: some View {
        List {
            ForEach(droppedFiles) { file in
                HStack {
                    if let data = file.thumbnailData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 50, height: 50)
                            .cornerRadius(4)
                    }
                    Text(file.name)
                    Text("Duration: \(file.duration)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    if file.status == .converting {
                        ProgressView(value: file.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                        Text("ETA: \(file.eta ?? "N/A")")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Button(action: {
                            if let idx = droppedFiles.firstIndex(of: file) {
                                droppedFiles[idx].status = .failed
                                FFMPEGConverter.cancelConversion()
                            }
                        }) {
                            Text("Cancel")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Text(statusText(for: file.status))
                        .font(.subheadline)
                        .foregroundColor(file.status == .done ? .green : (file.status == .converting ? .blue : .gray))
                    Spacer()
                    Text("\(file.size / 1024) KB")
                    Button(action: {
                        if let idx = droppedFiles.firstIndex(of: file) {
                            droppedFiles.remove(at: idx)
                        }
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(file.status == .converting)
                    if file.status == .done || file.status == .failed {
                        Button(action: {
                            if let idx = droppedFiles.firstIndex(of: file) {
                                droppedFiles[idx].status = .waiting
                            }
                        }) {
                            Text("Reset")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }

    func statusText(for status: ConversionManager.ConversionStatus) -> String {
        switch status {
        case .waiting:
            return "Waiting"
        case .converting:
            return "Converting"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

struct VideoFileListView_Previews: PreviewProvider {
    static var previews: some View {
        VideoFileListView(droppedFiles: .constant([
            VideoItem(
                url: URL(fileURLWithPath: "/tmp/SampleVideo.mp4"),
                name: "SampleVideo.mp4",
                size: 1048576,
                duration: "00:02:30",
                thumbnailData: nil,
                status: .waiting,
                progress: 0.0,
                eta: nil
            )
        ]), currentProgress: .constant(0.5))
    }
}
