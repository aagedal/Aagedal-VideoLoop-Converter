// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// Crop controls panel with aspect ratio picker and pixel inputs
struct CropControlsView: View {
    @Binding var item: VideoItem
    @ObservedObject var controller: PreviewPlayerController
    @Binding var isExpanded: Bool
    @State private var selectedAspectRatio: AspectRatio = .free

    // Pixel input states
    @State private var pixelX: String = "0"
    @State private var pixelY: String = "0"
    @State private var pixelWidth: String = "1920"
    @State private var pixelHeight: String = "1080"

    // Focus management for Tab navigation
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case x, y, width, height
    }

    private var sourceWidth: Int {
        item.metadata?.videoStream?.width ?? 1920
    }

    private var sourceHeight: Int {
        item.metadata?.videoStream?.height ?? 1080
    }

    private var configBinding: Binding<CropConfig> {
        // Lazy initialization pattern from AudioRoutingView
        Binding(
            get: {
                if let config = item.cropConfig {
                    return config
                } else {
                    // Default: full frame
                    return CropConfig(normalizedRect: .fullFrame)
                }
            },
            set: { newValue in
                item.cropConfig = newValue.isActive ? newValue : nil
                updatePixelInputsFromConfig()
            }
        )
    }

    var body: some View {
        if isExpanded {
            VStack(spacing: 4) {
                // Main controls row
                HStack(spacing: 8) {
                    // Aspect ratio picker
                    Picker("", selection: $selectedAspectRatio) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .onChange(of: selectedAspectRatio) { _, newRatio in
                        var config = configBinding.wrappedValue
                        config.aspectRatioLock = newRatio == .free ? nil : newRatio

                        // If not free, adjust the rectangle to match the aspect ratio
                        if let targetRatio = newRatio.numericRatio {
                            var rect = config.normalizedRect

                            // Calculate center point to maintain position
                            let centerX = rect.x + rect.width / 2
                            let centerY = rect.y + rect.height / 2

                            // Try to keep the same area, adjust both dimensions to match ratio
                            let area = rect.width * rect.height
                            // area = w * h, and w/h = targetRatio, so w = h * targetRatio
                            // area = h * targetRatio * h = h^2 * targetRatio
                            // h = sqrt(area / targetRatio)
                            var newHeight = sqrt(area / targetRatio)
                            var newWidth = newHeight * targetRatio

                            // Clamp to bounds
                            if newWidth > 1.0 {
                                newWidth = 1.0
                                newHeight = newWidth / targetRatio
                            }
                            if newHeight > 1.0 {
                                newHeight = 1.0
                                newWidth = newHeight * targetRatio
                            }

                            // Position centered on previous center
                            rect.width = newWidth
                            rect.height = newHeight
                            rect.x = max(0, min(1.0 - rect.width, centerX - rect.width / 2))
                            rect.y = max(0, min(1.0 - rect.height, centerY - rect.height / 2))

                            config.normalizedRect = rect
                        }

                        configBinding.wrappedValue = config
                        updatePixelInputsFromConfig()
                    }

                    Divider()
                        .frame(height: 20)

                    // Pixel inputs with auto-apply
                    compactPixelField(label: "X", value: $pixelX, field: .x, autoApply: true)
                    compactPixelField(label: "Y", value: $pixelY, field: .y, autoApply: true)
                    compactPixelField(label: "W", value: $pixelWidth, field: .width, autoApply: true)
                    compactPixelField(label: "H", value: $pixelHeight, field: .height, autoApply: true)

                    Divider()
                        .frame(height: 20)

                    // Quick actions
                    Button("Reset") {
                        resetCrop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Center") {
                        centerCrop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                // Warning message for Stream Copy preset
                if let config = item.cropConfig, config.isActive {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Note: Crop requires re-encoding and will not work with Stream Copy preset.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .onAppear {
                updatePixelInputsFromConfig()
                // Initialize aspect ratio from config
                if let config = item.cropConfig {
                    selectedAspectRatio = config.aspectRatioLock ?? .free
                }
            }
        }
    }

    private func compactPixelField(label: String, value: Binding<String>, field: Field, autoApply: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 12)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .font(.caption)
                .focused($focusedField, equals: field)
                .onSubmit {
                    if autoApply {
                        applyPixelInputs()
                    }
                }
        }
    }

    private func updatePixelInputsFromConfig() {
        let config = configBinding.wrappedValue
        let pixelRect = config.pixelRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight)

        pixelX = "\(pixelRect.x)"
        pixelY = "\(pixelRect.y)"
        pixelWidth = "\(pixelRect.width)"
        pixelHeight = "\(pixelRect.height)"
    }

    private func applyPixelInputs() {
        guard let x = Int(pixelX),
              let y = Int(pixelY),
              let width = Int(pixelWidth),
              let height = Int(pixelHeight) else {
            return
        }

        let pixelRect = PixelCropRect(x: x, y: y, width: width, height: height)
        var config = CropConfig.fromPixelRect(
            pixelRect,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            aspectRatioLock: selectedAspectRatio == .free ? nil : selectedAspectRatio
        )
        config.aspectRatioLock = selectedAspectRatio == .free ? nil : selectedAspectRatio
        configBinding.wrappedValue = config
    }

    private func resetCrop() {
        item.cropConfig = nil
        selectedAspectRatio = .free
        updatePixelInputsFromConfig()
    }

    private func centerCrop() {
        // Create a centered crop at 80% of source dimensions
        let centerX = 0.1
        let centerY = 0.1
        let cropWidth = 0.8
        let cropHeight = 0.8

        var config = CropConfig(
            normalizedRect: CropRect(x: centerX, y: centerY, width: cropWidth, height: cropHeight)
        )
        config.aspectRatioLock = selectedAspectRatio == .free ? nil : selectedAspectRatio
        configBinding.wrappedValue = config
    }
}
