//
//  DragAndDropView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//

import SwiftUI
import AppKit

struct DragAndDropView: NSViewRepresentable {
    @Binding var droppedFiles: [VideoItem]

    class Coordinator: NSObject, NSDraggingDestination {
        var parent: DragAndDropView

        init(parent: DragAndDropView) {
            self.parent = parent
        }

        func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
                for url in urls {
                    let name = url.lastPathComponent
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    let duration = "00:00:00"
                    let thumbnailData: Data? = nil
                    let newFile = VideoItem(url: url, name: name, size: size, duration: duration, thumbnailData: thumbnailData, status: .waiting, progress: 0.0, eta: nil)
                    DispatchQueue.main.async {
                        self.parent.droppedFiles.append(newFile)
                    }
                }
                return true
            }
            return false
        }

        func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            return .copy
        }

        func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            return true
        }

        func concludeDragOperation(_ sender: NSDraggingInfo?) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class DraggingView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            coordinator?.draggingEntered(sender) ?? []
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            coordinator?.prepareForDragOperation(sender) ?? false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            coordinator?.performDragOperation(sender) ?? false
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            coordinator?.concludeDragOperation(sender)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = DraggingView()
        view.coordinator = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
