# GEMINI.md

## Project Overview

This project is a macOS application named "Aagedal Media Converter". It is a lightweight and minimal application for batch encoding of video files. The application is written in Swift and uses the SwiftUI framework for its user interface.

The core functionality of the application is powered by `ffmpeg`, which is used for video conversion, and `ffprobe` for video metadata extraction. The application also utilizes `VLCKit` for video playback, managed through Carthage.

The architecture is based on modern Swift concurrency, with `actors` managing the conversion queue and `ffmpeg` processes.

## Building and Running

This is an Xcode project. To build and run the application, follow these steps:

1.  **Install Dependencies:**
    *   Install Carthage if you don't have it: `brew install carthage`
    *   Run `carthage bootstrap --platform macOS` in the project root to download and build the `VLCKit` dependency.

2.  **Open in Xcode:**
    *   Open the `Aagedal Media Converter.xcodeproj` file in Xcode.

3.  **Run the Application:**
    *   Select the "Agedal Media Converter" scheme and a macOS target (e.g., "My Mac").
    *   Click the "Run" button (or press `Cmd+R`).

**TODO:** It would be beneficial to add a command-line build script (e.g., using `xcodebuild`) for users who prefer not to use the Xcode GUI.

## Development Conventions

*   **Language:** The project is written entirely in Swift.
*   **UI:** The user interface is built with SwiftUI.
*   **Concurrency:** The project heavily uses Swift's modern concurrency features, including `async/await` and `actors`.
*   **Dependency Management:** Carthage is used for managing the `VLCKit` dependency.
*   **Coding Style:** The code is well-structured and follows modern Swift conventions. The use of `actors` for state management and concurrent operations is a key architectural pattern.
*   **Licensing:** The project is licensed under the GNU General Public License, version 3.0.

## Key Files

*   `Aagedal Media Converter/Aagedal_Media_Converter_App.swift`: The main entry point of the application.
*   `Aagedal Media Converter/UI/ContentView.swift`: The main SwiftUI view that constitutes the application's user interface.
*   `Aagedal Media Converter/Logic/ConversionManager.swift`: An `actor` that manages the queue of video conversions.
*   `Aagedal Media Converter/Logic/Conversion/FFMPEGConverter.swift`: An `actor` responsible for executing `ffmpeg` commands.
*   `Aagedal Media Converter/Logic/Conversion/FFMPEGCommandBuilder.swift`: A utility for constructing `ffmpeg` command-line arguments based on user-selected presets and options.
*   `Aagedal Media Converter/Logic/Conversion/ExportPreset.swift`: Defines the various export presets and their corresponding `ffmpeg` arguments.
*   `Cartfile`: Specifies the project's dependency on `VLCKit`.
*   `Aagedal Media Converter.xcodeproj`: The Xcode project file.
