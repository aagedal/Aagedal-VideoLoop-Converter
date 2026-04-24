// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Container view for all transcription settings (Whisper + Parakeet)
struct TranscriptionSettingsView: View {
    @AppStorage(AppConstants.defaultTranscriptionEngineKey) private var defaultEngine = AppConstants.defaultTranscriptionEngine
    @AppStorage(AppConstants.embedSubtitlesKey) private var embedSubtitles = AppConstants.defaultEmbedSubtitles

    var body: some View {
        Form {
            Section(header: Text("Default Transcription Engine")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Engine:", selection: $defaultEngine) {
                        Text("Whisper (FFmpeg built-in)").tag("whisper")
                        Text("Parakeet (NeMo MLX)").tag("parakeet")
                    }
                    .pickerStyle(.menu)

                    Text("The default engine used when enabling transcription on new items. You can override per item in the queue.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Embed subtitles into output file", isOn: $embedSubtitles)
                        .toggleStyle(SwitchToggleStyle())

                    Text("When enabled, the generated SRT will be muxed into the output video file as a subtitle track after transcription completes. The external SRT file is kept as well.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if embedSubtitles {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("Not all subtitle formats are compatible with MP4 and MOV containers. SRT subtitles will be converted to mov_text for MP4/MOV. For full compatibility, use MKV as the output format.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(8)
            }

            if defaultEngine == "whisper" {
                WhisperSettingsView()
            }

            if defaultEngine == "parakeet" {
                ParakeetSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    TranscriptionSettingsView()
}
