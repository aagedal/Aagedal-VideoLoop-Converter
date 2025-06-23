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
    var preset: ExportPreset
    
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if droppedFiles.isEmpty {
                // Empty state with drag and drop instructions
                VStack {
                    Image(systemName: "film.stack")
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
                            preset: preset,
                            onCancel: {
                                Task {
                                    await ConversionManager.shared.cancelItem(with: file.id)
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
            return handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("🔄 handleDrop called with \(providers.count) providers")
        let supportedExtensions = AppConstants.supportedVideoExtensions
        var handled = false
        
        for provider in providers {
            print("📦 Processing provider: \(provider)")
            // Use the proper API to load file URLs
            if provider.canLoadObject(ofClass: URL.self) {
                print("✅ Provider can load URL")
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error = error {
                        print("❌ Error loading URL: \(error)")
                        return
                    }
                    if let url = url {
                        print("📁 Loaded URL: \(url)")
                        
                        // For drag and drop, the URL already has temporary access
                        // We need to start accessing the security-scoped resource immediately
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        print("🔐 Security-scoped access granted: \(hasAccess)")
                        
                        Task { @MainActor in
                            await self.processFileURL(url, supportedExtensions: supportedExtensions, hasSecurityAccess: hasAccess)
                        }
                    } else {
                        print("❌ Provider cannot load URL")
                    }
                }
                handled = true
            } else {
                print("❌ Provider cannot load URL")
            }
        }
        
        print("🔄 handleDrop returning: \(handled)")
        return handled
    }
    
    @MainActor
    private func processFileURL(_ url: URL, supportedExtensions: Set<String>, hasSecurityAccess: Bool = false) async {
        print("🔍 Processing file URL: \(url)")
        
        // Get the file extension and check if it's supported
        let fileExtension = url.pathExtension.lowercased()
        print("📄 File extension: '\(fileExtension)'")
        print("✅ Supported extensions: \(supportedExtensions)")
        
        guard !fileExtension.isEmpty,
              supportedExtensions.contains(fileExtension) else {
            print("❌ File extension '\(fileExtension)' not supported")
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print("🔒 Released security-scoped resource (unsupported file)")
            }
            return
        }
        
        print("✅ File extension is supported")
        
        // Handle security-scoped access based on the source
        var needsBookmarkAccess = false
        if !hasSecurityAccess {
            // Attempt to use an existing bookmark for persistent access
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                needsBookmarkAccess = true
                print("🔓 Successfully accessed security-scoped resource via bookmark")
            } else {
                // No bookmark found – rely on direct entitlements (e.g. Downloads/Movie directory access)
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print("🟢 Proceeding with direct file access (no bookmark needed)")
                } else {
                    print("❌ No bookmark and file not readable – access denied")
                    return
                }
            }
        } else {
            print("🔓 Using existing security-scoped resource access")
        }
        
        defer {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print("🔒 Released security-scoped resource (drag and drop)")
            } else if needsBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
                print("🔒 Released security-scoped resource (bookmark)")
            }
        }
        
        // Save the bookmark for future access
        let bookmarkSaved = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        print("💾 Bookmark saved: \(bookmarkSaved)")
        
        // Get the output folder from UserDefaults or use default
        let outputFolder = UserDefaults.standard.string(forKey: "outputFolder") 
            ?? AppConstants.defaultOutputDirectory.path
            
        if let videoItem = await VideoFileUtils.createVideoItem(
            from: url,
            outputFolder: outputFolder,
            preset: preset
        ) {
            print("🎬 Created video item: \(videoItem.name)")
            // Check for duplicates before adding
            if !self.droppedFiles.contains(where: { $0.url == videoItem.url }) {
                self.droppedFiles.append(videoItem)
                print("✅ Added video item to list. Total items: \(self.droppedFiles.count)")
            } else {
                print("⚠️ Video item already exists in list")
            }
        } else {
            print("❌ Failed to create video item")
        }
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
        case .cancelled:
            return "Cancelled"
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
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo2.mp4"),
                    name: "SampleVideo2.mp4",
                    size: 1048576,
                    duration: "00:01:30",
                    thumbnailData: nil,
                    status: .done,
                    progress: 0.0,
                    eta: nil
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo3.mp4"),
                    name: "SampleVideo.mp4",
                    size: 1048576,
                    duration: "00:05:30",
                    thumbnailData: nil,
                    status: .cancelled,
                    progress: 0.0,
                    eta: nil
                )
            ]),
            currentProgress: .constant(0.5),
            onFileImport: {},
            onDoubleClick: {},
            onDelete: { _ in },
            onReset: { _ in },
            preset: .videoLoop
        )
    }
}
