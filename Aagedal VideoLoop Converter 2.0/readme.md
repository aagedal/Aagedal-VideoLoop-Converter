# Aagedal VideoLoop Converter 2.0

A lightweight macOS application for converting video files into formats that **loop seamlessly** and play reliably across platforms and web browsers. Powered by FFmpeg under the hood and written entirely in Swift / SwiftUI.

---

## Key Features

- **Drag-and-Drop** or File Picker import
- Batch conversion with per-file progress and overall dock progress indicator
- **Export Presets**  
  • Video Loop (silent)  
  • Video Loop w/ Audio  
  • TV Quality HD / 4K  
  • ProRes (editing)  
  • Animated AVIF  
  • HEVC Proxy 1080 p
- Automatic duration warning if a VideoLoop clip exceeds 15 s (may not autoplay)
- Sandboxed with Security-Scoped Bookmarks for persistent file access
- Localised string catalogs (/)

---

## Requirements

|                | Minimum |
|----------------|---------|
| macOS          | 15.0 (Sonoma) |

---

## Building & Running

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/Aagedal-VideoLoop-Converter-2.0.git
   cd Aagedal-VideoLoop-Converter-2.0
   ```
2. Open `Aagedal VideoLoop Converter 2.0.xcodeproj` in Xcode.
3. Select the *Aagedal VideoLoop Converter 2.0* scheme and **Run** (⌘R).

> The project uses Swift Strict Concurrency (`complete`) and upcoming language features—Xcode 16 is required.

---

## Usage

1. Launch the app.
2. Drag video files onto the window **or** click the plus button to import files.
3. Select an **Export Preset** from the toolbar menu.
4. Hit the green *Convert* button or press ⌘⏎.
5. Converted files appear in your chosen *Output Folder* (defaults to `~/Movies/VideoLoopExports`).

### 15-Second Autoplay Warning

Web browsers often refuse to autoplay long, looping videos with sound. The app shows a yellow ⚠️ icon when the VideoLoop presets are applied to clips longer than 15 s, prompting you to trim or pick another preset.

---

## Preset Details

| Preset | Extension | Purpose | Notes |
|--------|-----------|---------|-------|
| Video Loop | .mp4 | Small, silent loops for web GIF replacement | H.264, CRF 23, 1080p max |
| Video Loop w/ Audio | .mp4 | Loops with first audio track | H.264 @192 kbps AAC audio |
| TV Quality HD | .mov | High-bitrate HEVC for HD playback | 10-bit 4:2:2, 18 Mbps |
| TV Quality 4K | .mov | 4K HEVC variant | 10-bit 4:2:2, 30 Mbps |
| ProRes | .mov | Editing master | Apple ProRes 422 |
| Animated AVIF | .avif | Modern efficient loops | AV1 (svtav1) encoder, 720p max |
| HEVC Proxy 1080p | .mov | Low-bitrate proxy for NLEs | 6 Mbps, 10-bit |

---

## License

Copyright 2025 Truls Aagedal

Distributed under the MIT License. See `LICENSE` for more information.
