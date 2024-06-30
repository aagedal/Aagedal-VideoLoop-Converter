//
//  Aagedal_VideoLoop_Converter_2_0App.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.
//

import SwiftUI
import SwiftData

@main
struct Aagedal_VideoLoop_Converter_2_0App: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
