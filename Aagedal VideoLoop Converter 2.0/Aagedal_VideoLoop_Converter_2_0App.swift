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
    var body: some Scene {
        WindowGroup {
            VStack {
                ContentView()
            }.toolbar {
                ToolbarItemGroup(placement: .primaryAction, content: {
                                    // Tint this green and linkup to logic. Replacing the other conversion button.
                                    Button(action: {}, label: {
                                        Image(systemName: "play.fill")
                                        Text(verbatim: "Start Conversion")
                                    }
                                    )
                                })
            }.tint(.green)
        }.windowStyle(.automatic)
            .windowToolbarStyle(.automatic)
    }
}
