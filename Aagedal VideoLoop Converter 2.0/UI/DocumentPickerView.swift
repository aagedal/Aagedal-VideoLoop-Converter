//
//  DocumentPickerView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 02/07/2024.
//
import SwiftUI

struct DocumentPickerView: View {
    @Binding var droppedFiles: [VideoItem]
    @Binding var isPresented: Bool
    @Binding var selectedFolder: URL?

    var body: some View {
        VStack {
            // Your UI components
            Button(action: {
                self.isPresented = false
            }) {
                Text("Done")
            }
        }
        .onAppear {
            Task {
                await self.openFolderSelection()
            }
        }
    }

    @MainActor
    private func openFolderSelection() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let response = await withCheckedContinuation { continuation in
            panel.begin { result in
                continuation.resume(returning: result)
            }
        }
        if response == .OK {
            self.selectedFolder = panel.url
        }
        self.isPresented = false
    }
}
