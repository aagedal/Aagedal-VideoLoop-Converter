//
//  VideoFileListView.swift.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct VideoFileListView: View {
    @Binding var droppedFiles: [VideoItem]
    @Binding var currentProgress: Double
    var onFileImport: () -> Void
    var onDoubleClick: () -> Void
    var onDelete: (IndexSet) -> Void
    var onReset: (Int) -> Void
    
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if droppedFiles.isEmpty {
                // Empty state with drag and drop instructions
                VStack {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                        .padding()
                    Text("Drag and drop video files here")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("or double-click to import files")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.windowBackgroundColor))
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
            } else {
                // File list
                List {
                    ForEach(Array(droppedFiles.enumerated()), id: \.element.id) { index, file in
                        VideoFileRowView(
                            file: file,
                            onCancel: {
                                droppedFiles[index].status = .failed
                                Task {
                                    await ConversionManager.shared.cancelConversion()
                                }
                            },
                            onDelete: {
                                onDelete(IndexSet(integer: index))
                            },
                            onReset: {
                                onReset(index)
                            }
                        )
                        .padding([.vertical], 4)
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(PlainListStyle())
            }
            
            // Drag and drop overlay
            if isTargeted {
                Color.blue.opacity(0.1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                            .foregroundColor(.blue)
                    )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let supportedTypes = AppConstants.supportedVideoTypes
        
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   supportedTypes.contains(where: { $0.lowercased() == url.pathExtension.lowercased() }) {
                    DispatchQueue.main.async {
                        Task {
                            if let videoItem = await VideoFileUtils.createVideoItem(from: url) {
                                if !self.droppedFiles.contains(where: { $0.url == videoItem.url }) {
                                    self.droppedFiles.append(videoItem)
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    private func progressText(for item: VideoItem) -> String {
        switch item.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = item.eta {
                return "Converting... ETA: \(eta)"
            } else {
                return "Converting..."
            }
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

struct VideoFileListView_Previews: PreviewProvider {
    static var previews: some View {
        VideoFileListView(
            droppedFiles: .constant([
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
            ]),
            currentProgress: .constant(0.5),
            onFileImport: {},
            onDoubleClick: {},
            onDelete: { _ in },
            onReset: { _ in }
        )
    }
}
