// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Real-time audio level meter visualization
struct AudioMeterView: View {
    let levels: UniversalAudioMeterService.AudioLevels
    let meterHeight: CGFloat
    
    private let meterWidth: CGFloat = 12
    
    init(
        levels: UniversalAudioMeterService.AudioLevels,
        meterHeight: CGFloat = 180,
        showLabels: Bool = true
    ) {
        self.levels = levels
        self.meterHeight = meterHeight
    }
    
    var body: some View {
        HStack(spacing: 4) {
            // Labels are now always shown, so no `if showLabels`
            levelScale
            
            meterBar(level: levels.leftChannel, label: "L", height: meterHeight)
            meterBar(level: levels.rightChannel, label: "R", height: meterHeight)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func meterBar(level: Float, label: String, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            
            LevelBar(level: level, range: -50...0, height: height)
                .frame(width: meterWidth)
        }
    }
    
    @ViewBuilder
    private var levelScale: some View {
        VStack(spacing: 0) {
            Text("")
                .font(.system(size: 6))
                .frame(height: 10)
            
            VStack(alignment: .trailing, spacing: 0) {
                dbLabel("0")
                Spacer()
                dbLabel("-10")
                Spacer()
                dbLabel("-20")
                Spacer()
                dbLabel("-30")
                Spacer()
                dbLabel("-40")
                Spacer()
                dbLabel("-50")
            }
            .frame(height: meterHeight)
        }
    }
    
    private func dbLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
    }
}

/// Individual level bar component
private struct LevelBar: View {
    let level: Float // dB value, typically -50 to 0
    let range: ClosedRange<Float>
    let height: CGFloat
    
    init(level: Float, range: ClosedRange<Float> = -50...0, height: CGFloat = 180) {
        self.level = level
        self.range = range
        self.height = height
    }
    
    private var normalizedLevel: CGFloat {
        // Convert dB range to 0.0-1.0
        let dbRange = range.upperBound - range.lowerBound
        let clamped = max(range.lowerBound, min(level, range.upperBound))
        return CGFloat((clamped - range.lowerBound) / dbRange)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                
                // Gradient Source (Full Height, Stationary)
                Rectangle()
                    .fill(levelGradient)
                    .mask(
                        // Mask reveals gradient from bottom up
                        Rectangle()
                            .frame(height: geometry.size.height * normalizedLevel)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    )
                
                // Peak markers at specific dB levels
                VStack(spacing: 0) {
                    peakMarker(at: 0.0) // 0 dB
                    Spacer()
                    peakMarker(at: 0.2) // -10 dB (for -50 to 0 range)
                    Spacer()
                    peakMarker(at: 0.4) // -20 dB
                    Spacer()
                    peakMarker(at: 0.6) // -30 dB
                    Spacer()
                    peakMarker(at: 0.8) // -40 dB
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: height)
    }
    
    private var levelGradient: LinearGradient {
        // Top (0 dB) = Red
        // Bottom (-50 dB) = Green
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.red, location: 0.0),      // 0 dB (Top)
                .init(color: Color.red, location: 0.2),      // -10 dB
                .init(color: Color.yellow, location: 0.4),   // -20 dB
                .init(color: Color.green, location: 0.6),    // -30 dB
                .init(color: Color.green, location: 1.0)     // -50 dB (Bottom)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private func peakMarker(at position: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.3))
            .frame(height: 1)
    }
}

// MARK: - Previews

#Preview("Active Audio") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: UniversalAudioMeterService.AudioLevels(
                leftChannel: -12.0,
                rightChannel: -8.0,
                peak: -8.0
            ),
            showLabels: false
        )
    }
}

#Preview("With Labels") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: UniversalAudioMeterService.AudioLevels(
                leftChannel: -20.0,
                rightChannel: -18.0,
                peak: -18.0
            ),
            showLabels: true
        )
    }
}

#Preview("Silence") {
    ZStack {
        Color.black
        AudioMeterView(
            levels: .silence,
            showLabels: false
        )
    }
}
