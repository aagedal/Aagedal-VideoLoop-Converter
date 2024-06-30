//
//  Item.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 30/06/2024.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
