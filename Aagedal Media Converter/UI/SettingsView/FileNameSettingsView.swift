// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct FileNameSettingsView: View {
    @AppStorage(AppConstants.enableFileNameProcessingKey) private var enableFileNameProcessing = true
    @AppStorage(AppConstants.fileNameReplaceSpacesKey) private var fileNameReplaceSpaces = AppConstants.defaultFileNameReplaceSpaces
    @AppStorage(AppConstants.fileNameReplaceScandinavianCharsKey) private var fileNameReplaceScandinavianChars = AppConstants.defaultFileNameReplaceScandinavianChars
    @AppStorage(AppConstants.fileNameRemoveSpecialCharsKey) private var fileNameRemoveSpecialChars = AppConstants.defaultFileNameRemoveSpecialChars
    @AppStorage(AppConstants.fileNameIncludePresetSuffixKey) private var fileNameIncludePresetSuffix = AppConstants.defaultFileNameIncludePresetSuffix

    var body: some View {
        Form {
            fileNameSection
        }
        .formStyle(.grouped)
    }

    private var fileNameSection: some View {
        Section(header: Text("File Names")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable filename processing", isOn: $enableFileNameProcessing)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, spaces and special characters in filenames are sanitized")

                if enableFileNameProcessing {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Replace spaces with underscores", isOn: $fileNameReplaceSpaces)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                        Toggle("Convert Scandinavian characters (æ, ø, å)", isOn: $fileNameReplaceScandinavianChars)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                        Toggle("Remove special characters", isOn: $fileNameRemoveSpecialChars)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                Toggle("Include preset suffix in filename", isOn: $fileNameIncludePresetSuffix)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, preset suffixes like '_loop' or '_tv' are added to output filenames")
                Text("When disabled, output filenames will not include preset-specific suffixes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }
}

#Preview {
    FileNameSettingsView()
}
