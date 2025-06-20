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
                ZStack {
                    Rectangle().opacity(0.4).foregroundColor(.indigo).cornerRadius(8).shadow(radius: 8)
                    HStack {
                        ZStack {
                            //Replace image icon with the videofile thumbnail. Generated from 10% into the video file, as the beginning might be black and not represent the content. The thumbnail should be generated with ffmpeg if file format isn't supported by AVFoundation. Thumbnail should fit not fill the rectangle.
                            Rectangle().frame(width: 100, height: 100).cornerRadius(9).foregroundColor(.black).padding(2)
                            Image(systemName: "film").padding().font(.largeTitle)
                            if let data = file.thumbnailData, let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 100, height: 100)
                                    .cornerRadius(4)
                            }
                        }.padding(.leading)
                        VStack {
                            HStack {
                                Text(file.name).font(.headline)
                                Text("→")
                                // Fix this!
                                // Text( \(file.destinationFileName))
                                Spacer()
                            }
                            HStack {
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
                                        if let idx = droppedFiles.firstIndex(where: { $0.id == file.id }) {
                                            droppedFiles[idx].status = .failed
                                            Task {
                                                await ConversionManager.shared.cancelConversion()
                                            }
                                        }
                                    }) {
                                        Text("Cancel")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                Text("|     Input Size: \(file.size / 1024) KB").font(.subheadline).foregroundStyle(.gray)
                                Text("  |   Status:").font(.subheadline).foregroundStyle(.gray)
                                Text(statusText(for: file.status))
                                    .font(.subheadline)
                                    .foregroundColor(file.status == .done ? .green : (file.status == .converting ? .blue : .gray))
                                Spacer()
                                VStack {
                                    //Right side buttons
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
                                            Image(systemName: "arrow.uturn.backward")
                                            Text("Reset")
                                                .foregroundColor(.blue)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            Spacer()
                        }.padding()
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
            ),
            VideoItem(
                url: URL(fileURLWithPath: "/tmp/Sample Video 2.mp4"),
                name: "Sample Video 2.mp4",
                size: 10576,
                duration: "00:01:14",
                thumbnailData: nil,
                status: .waiting,
                progress: 0.0,
                eta: nil
            )
        ]), currentProgress: .constant(0.5))
    }
}
