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
    
    // Todo: Remove special characters, but not underscores og hyphens.
    
    return cleanedName
}
