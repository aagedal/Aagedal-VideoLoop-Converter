//
//  ContentView.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.

import SwiftUI

struct ContentView: View {
    @State private var droppedFiles: [VideoItem] = []
    @State private var currentOutputFolder: URL? = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.appendingPathComponent("VideoLoopExports")
    @State private var showDocumentPicker = false

    var body: some View {
        ZStack {
            DragAndDropView(droppedFiles: $droppedFiles)
                .edgesIgnoringSafeArea(.all)
            VStack {
                HStack {
                    Button {
                        Task {
                            if await ConversionManager.shared.isConvertingStatus() {
                                await ConversionManager.shared.cancelConversion()
                            } else {
                                await ConversionManager.shared.startConversion(droppedFiles: $droppedFiles, outputFolder: currentOutputFolder?.path() ?? "/Users/user/Downloads/")
                            }
                        }
                    } label: {
                            Text(ConversionManager.shared.isConvertingStatus() ? "Cancel" : "Start Converting")
                                .padding()
                                .background(ConversionManager.shared.isConvertingStatus() ? Color.red : Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                    }
                    .padding()
                    Spacer()
                    Button {
                        showDocumentPicker.toggle()
                    } label: {
                        Text("Select Output Folder")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding()
                }
                VideoFileListView(droppedFiles: $droppedFiles, currentProgress: .constant(0.0))
                    .padding()
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView(droppedFiles: $droppedFiles, isPresented: $showDocumentPicker, selectedFolder: $currentOutputFolder)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
