//
//  Aagedal_VideoLoop_Converter_2_0App.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.
//

import SwiftUI
import SwiftData
import AppKit

@main
struct Aagedal_VideoLoop_Converter_2_0App: App {
    var body: some Scene {
        WindowGroup {
            VStack {
                ContentView()
            }
        }.windowStyle(.automatic)
            .windowToolbarStyle(.automatic)
            .windowResizability(.contentMinSize)
            // Add File → Import… menu command
            .commands {
                CommandGroup(after: .importExport) {
                    Button("Import…") {
                        NotificationCenter.default.post(name: .showFileImporter, object: nil)
                    }
                    .keyboardShortcut("i", modifiers: .command)
                }
            }
        Settings {
            SettingsView().keyboardShortcut(",",modifiers: .command)
        }
    }
}
