//
//  FileNameProcessor.swift
//  Aagedal VideoLoop Converter 2.0
//
//  Created by Truls Aagedal on 20/06/2025.
//

import Foundation

/* Tasks:
- Replace spaces with underscores.
- Replace æ, ø, å with ae, o, aa.
- Replace special characters with hyphens.
- Allow underscores and hyphens.
- Keep case.
 */

func cleanFileName(_ input: String) -> String {
    var cleanedName = input
        .replacingOccurrences(of: " ", with: "_")
    
    cleanedName = cleanedName
        .replacingOccurrences(of: "æ", with: "ae")
        .replacingOccurrences(of: "ø", with: "o")
        .replacingOccurrences(of: "å", with: "aa")
    cleanedName = cleanedName
        .replacingOccurrences(of: "Æ", with: "AE")
        .replacingOccurrences(of: "Ø", with: "O")
        .replacingOccurrences(of: "Å", with: "AA")
    
    // Remove special characters but keep letters, numbers, underscores, and hyphens
    let allowedChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    cleanedName = cleanedName.filter { char in
        let lowercasedChar = String(char).lowercased()
        return allowedChars.contains(char) || lowercasedChar != String(char)
    }
    
    // Remove any remaining special characters except underscores and hyphens
    let pattern = "[^a-zA-Z0-9_-]"
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
    
    return cleanedName
}
