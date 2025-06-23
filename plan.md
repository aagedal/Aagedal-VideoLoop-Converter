# Aagedal VideoLoop Converter 3.0 Implementation Plan

## Notes
- The primary architectural goal is to avoid GPLv3 licensing by using `ffmpeg` as an external command-line tool rather than a linked library.
- The application will feature a dual-backend design:
  1.  **Primary Backend:** Uses native Apple APIs (`AVFoundation`, `VideoToolbox`) for core functionality.
  2.  **Optional Backend:** Uses an external `ffmpeg` binary for extended format support and features.
- The native backend will support MXF (OP-1a ProRes) and multi-channel audio for input on macOS 15+, with output limited to standard MOV/MP4 containers.
- The `ffmpeg` backend will be enabled only if a `ffmpeg` executable is detected on the user's system.
- A protocol-based abstraction (`VideoEncoder`) will be used to seamlessly switch between the two backends.
- The user interface must dynamically adapt, showing available encoding presets based on whether `ffmpeg` is installed.

## Task List
- [ ] **Project Setup & Core Structure**
  - [ ] Create a new Swift/SwiftUI project targeting macOS 15+.
  - [ ] Define the `VideoEncoder` protocol to abstract encoding operations.
  - [ ] Define data structures for encoding presets.
- [ ] **FFmpeg Detection & Backend Selection**
  - [ ] Implement a utility to detect the `ffmpeg` executable in common Homebrew paths (`/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`).
  - [ ] Create a manager or factory to determine the active backend at launch.
- [ ] **Native AVFoundation Encoder (`AVFEncoder`)**
  - [ ] Implement the `AVFEncoder` class, conforming to the `VideoEncoder` protocol.
  - [ ] Add logic to read video and multi-channel audio tracks from source files using `AVAssetReader`.
  - [ ] Add logic to write video and audio to MOV/MP4 files using `AVAssetWriter`.
  - [ ] Test ingestion of MXF/ProRes source files.
- [ ] **External FFmpeg Encoder (`FFMPEGEncoder`)**
  - [ ] Implement the `FFMPEGEncoder` class, conforming to the `VideoEncoder` protocol.
  - [ ] Add logic to construct and execute `ffmpeg` commands using `Process`.
  - [ ] Implement a parser for `ffmpeg`'s stderr to report progress.
- [ ] **UI & User Experience**
  - [ ] Build the main UI for file selection, preset configuration, and output destination.
  - [ ] Implement a dynamic preset list that reflects the available backend.
  - [ ] Create a progress view for active encoding operations.
  - [ ] Design and implement a user-guidance sheet that appears when an `ffmpeg`-only feature is selected without `ffmpeg` being installed.
- [ ] **Integration & Final Testing**
  - [ ] Connect the UI to the encoding backend logic.
  - [ ] Perform end-to-end testing for both backends with various source files (MXF, MOV) and presets.
  - [ ] Verify multi-channel audio is handled correctly in both paths.

## Current Goal
Set up the project and define the core encoder protocol.