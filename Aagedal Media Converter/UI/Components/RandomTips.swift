// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

@MainActor
enum RandomTips {
    static let tips: [LocalizedStringKey] = [
        "Tip: You can change the default encoding preset in the Settings menu.",
        "Tip: Press Tab to quickly jump between comment fields of different items.",
        "Tip: Import files with ⌘I, and start converting with ⌘Enter.",
        "Tip: Use ⌘T to open the trim editor for the selected file.",
        "Tip: Hold Option while resizing the crop box to resize both axes at once.",
        "Tip: You can drag items to reorder them in the queue.",
        "Tip: Hold Option and click Reset to clear both trim points and other settings.",
        "Tip: Press F to play the selected video in fullscreen.",
        "Tip: Use ⌘↑ and ⌘↓ to move selected items up and down in the queue.",
        "Tip: Set up a Watch Folder in Settings to automatically import new files.",
        "Tip: Use Option+A to configure audio routing for the selected file.",
        "Tip: Press ⌘D to toggle the date tag on the selected item.",
        "Tip: In both the Trim Player and the Fullscreen Player, you can use JKL to play backwards, pause, and play forwards. Just like in most NLEs.",
        "Tip: In both the Trim Player and the Fullscreen Player, you can use arrow keys to jump between frames.",
        "Tip: In both the Trim Player and the Fullscreen Player, you can start typing a number to enter a timecode. Press enter to jump to that timecode.",
        "Tip: In both the Trim Player and the Fullscreen Player, enter + or - before a number to jump that many seconds forward or backward. If the frame counter is active you will instead jump that many frames.",
        "Tip: Use T while in either player view, will change the timecode display to show source timecode, relative timecode or frame counter.",
        "Tip: Use Command + S while in either player view will save a still image of the current frame.",
        "Tip: Use Control + M will mute the selected files in the queue.",
    ]

    static func randomTip() -> LocalizedStringKey {
        tips.randomElement() ?? tips[0]
    }
}
