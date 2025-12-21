// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Utility for processing and sanitizing file names.
struct FileNameProcessor {
    /// Processes a file name to ensure it's safe for use in file systems.
    /// - Parameter input: The input file name to process
    /// - Returns: A sanitized version of the input string with spaces replaced by underscores,
    ///   special characters removed, and other sanitization applied. If filename processing is disabled
    ///   in user preferences, returns the input unchanged.
    static func processFileName(_ input: String) -> String {
        // Check if filename processing is enabled in user preferences
        let isEnabled = UserDefaults.standard.object(forKey: AppConstants.enableFileNameProcessingKey) as? Bool ?? true

        // If disabled, return the original input
        guard isEnabled else {
            return input
        }

        // Check individual processing options
        let replaceSpaces = UserDefaults.standard.object(forKey: AppConstants.fileNameReplaceSpacesKey) as? Bool ?? AppConstants.defaultFileNameReplaceSpaces
        let replaceScandinavianChars = UserDefaults.standard.object(forKey: AppConstants.fileNameReplaceScandinavianCharsKey) as? Bool ?? AppConstants.defaultFileNameReplaceScandinavianChars
        let removeSpecialChars = UserDefaults.standard.object(forKey: AppConstants.fileNameRemoveSpecialCharsKey) as? Bool ?? AppConstants.defaultFileNameRemoveSpecialChars

        var cleanedName = input

        // Replace spaces with underscores
        if replaceSpaces {
            cleanedName = cleanedName.replacingOccurrences(of: " ", with: "_")
        }

        // Replace Scandinavian characters
        if replaceScandinavianChars {
            cleanedName = cleanedName
                .replacingOccurrences(of: "æ", with: "ae")
                .replacingOccurrences(of: "ø", with: "o")
                .replacingOccurrences(of: "å", with: "aa")
                .replacingOccurrences(of: "Æ", with: "AE")
                .replacingOccurrences(of: "Ø", with: "O")
                .replacingOccurrences(of: "Å", with: "AA")
        }

        // Remove special characters but keep letters, numbers, underscores, and hyphens
        if removeSpecialChars {
            let pattern = "[^a-zA-Z0-9_\\- ]"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleanedName.startIndex..<cleanedName.endIndex, in: cleanedName)
                cleanedName = regex.stringByReplacingMatches(
                    in: cleanedName,
                    range: range,
                    withTemplate: ""
                )
            }

            // Remove any leading/trailing special characters
            cleanedName = cleanedName.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        }

        return cleanedName.isEmpty ? "unnamed" : cleanedName
    }

    /// Returns whether preset suffixes should be included in output filenames.
    static var includePresetSuffix: Bool {
        UserDefaults.standard.object(forKey: AppConstants.fileNameIncludePresetSuffixKey) as? Bool ?? AppConstants.defaultFileNameIncludePresetSuffix
    }
}
