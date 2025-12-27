// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// Manages secure credential storage in macOS Keychain
final class KeychainCredentialManager: @unchecked Sendable {
    static let shared = KeychainCredentialManager()

    private let serviceName = "com.aagedal.media-converter.upload"

    private init() {}

    // MARK: - Public Methods

    /// Saves a password for the given server and username
    /// - Parameters:
    ///   - server: The server hostname
    ///   - username: The username
    ///   - password: The password to store
    func saveCredential(server: String, username: String, password: String) throws {
        guard !server.isEmpty, !username.isEmpty else {
            throw KeychainError.invalidParameters
        }

        let account = buildAccountString(server: server, username: username)

        // Delete existing credential first (if any)
        try? deleteCredential(server: server, username: username)

        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.encodingError
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves a password for the given server and username
    /// - Parameters:
    ///   - server: The server hostname
    ///   - username: The username
    /// - Returns: The password if found, nil otherwise
    func getCredential(server: String, username: String) throws -> String? {
        guard !server.isEmpty, !username.isEmpty else {
            throw KeychainError.invalidParameters
        }

        let account = buildAccountString(server: server, username: username)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingError
        }

        return password
    }

    /// Deletes a stored credential
    /// - Parameters:
    ///   - server: The server hostname
    ///   - username: The username
    func deleteCredential(server: String, username: String) throws {
        let account = buildAccountString(server: server, username: username)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)

        // Ignore "item not found" error - it's fine if there's nothing to delete
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Checks if a credential exists for the given server and username
    func hasCredential(server: String, username: String) -> Bool {
        guard let _ = try? getCredential(server: server, username: username) else {
            return false
        }
        return true
    }

    /// Deletes all credentials stored by this app
    func deleteAllCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Private Methods

    private func buildAccountString(server: String, username: String) -> String {
        return "\(username)@\(server)"
    }
}

// MARK: - Error Types

enum KeychainError: Error, LocalizedError {
    case invalidParameters
    case encodingError
    case decodingError
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidParameters:
            return "Invalid server or username"
        case .encodingError:
            return "Failed to encode password"
        case .decodingError:
            return "Failed to decode password"
        case .saveFailed(let status):
            return "Failed to save credential: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .retrieveFailed(let status):
            return "Failed to retrieve credential: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .deleteFailed(let status):
            return "Failed to delete credential: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        }
    }
}
