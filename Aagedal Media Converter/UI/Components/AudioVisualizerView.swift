// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AudioVisualizerView: View {
    let samples: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black,
                        Color.gray.opacity(0.85)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                Canvas { context, size in
                    let path = waveformPath(size: size)
                    guard !path.isEmpty else { return }

                    let gradient = Gradient(stops: [
                        .init(color: Color.blue.opacity(0.85), location: 0),
                        .init(color: Color.purple.opacity(0.35), location: 0.7)
                    ])

                    context.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: size.width, y: size.height)
                        )
                    )

                    context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 1.25)
                }
                .allowsHitTesting(false)
            }
            .clipShape(Rectangle())
        }
        .allowsHitTesting(false)
    }

    private func waveformPath(size: CGSize) -> Path {
        var path = Path()
        guard size.width > 0, size.height > 0, !samples.isEmpty else {
            return path
        }

        let midY = size.height / 2
        let divisor = max(samples.count - 1, 1)
        let step = size.width / CGFloat(divisor)

        path.move(to: CGPoint(x: 0, y: midY))
        for (index, amplitude) in samples.enumerated() {
            let x = CGFloat(index) * step
            let y = midY - (amplitude * midY)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        for index in samples.indices.reversed() {
            let x = CGFloat(index) * step
            let y = midY + (samples[index] * midY)
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.closeSubpath()
        return path
    }
}

enum AudioVisualizer {
    static let maxSampleCount = 160

    static func normalizedLevel(from dB: Float) -> CGFloat {
        let minimumDB: Float = -60
        let clamped = max(minimumDB, min(dB, 0))
        return CGFloat((clamped - minimumDB) / -minimumDB)
    }
}
