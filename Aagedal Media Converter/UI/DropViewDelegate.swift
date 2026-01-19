// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import UniformTypeIdentifiers

struct DropViewDelegate: DropDelegate {
    let item: VideoItem
    @Binding var items: [VideoItem]
    @Binding var isReordering: Bool
    @Binding var isEncoding: Bool
    var onMove: (IndexSet, Int) -> Void
    
    func performDrop(info: DropInfo) -> Bool {
        isReordering = false
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard !isEncoding else { return }

        guard let itemProvider = info.itemProviders(for: [.text]).first else {
            return
        }

        itemProvider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { data, _ in
            let idString: String?
            if let data = data as? Data {
                idString = String(data: data, encoding: .utf8)
            } else if let str = data as? String {
                idString = str
            } else if let str = data as? NSString {
                idString = str as String
            } else {
                idString = nil
            }

            guard let idString, let draggedId = UUID(uuidString: idString) else {
                return
            }

            DispatchQueue.main.async {
                isReordering = true
                moveItem(with: draggedId, to: item.id)
            }
        }
    }
    
    private func moveItem(with draggedId: UUID, to targetId: UUID) {
        guard let fromIndex = items.firstIndex(where: { $0.id == draggedId }),
              let toIndex = items.firstIndex(where: { $0.id == targetId }),
              fromIndex != toIndex else {
            return
        }

        withAnimation {
            var updatedItems = items
            updatedItems.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )

            if updatedItems != items {
                items = updatedItems
                onMove(IndexSet(integer: fromIndex), toIndex)
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: isEncoding ? .forbidden : .move)
    }
    
    func dropExited(info: DropInfo) {
        isReordering = false
    }
}
