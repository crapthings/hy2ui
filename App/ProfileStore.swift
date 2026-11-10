import Foundation
import Security

/// Persists versioned profile metadata on disk and versioned credentials in the macOS Keychain.
@MainActor
final class ProfileStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("servers.json") }
    private var legacyFile: URL { directory.appendingPathComponent("profile.json") }

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hy2UI", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeLegacySessionFiles()
    }

    func load() throws -> ServerLibrary {
        if FileManager.default.fileExists(atPath: file.path) {
            return try PersistedConfiguration.decodeLibrary(Data(contentsOf: file))
        }
        if FileManager.default.fileExists(atPath: legacyFile.path) {
            let profile = try PersistedConfiguration.decodeProfile(Data(contentsOf: legacyFile))
            return try ServerLibrary(profiles: [profile], selectedID: profile.id)
        }
        return ServerLibrary()
    }

    func select(_ id: UUID) throws {
        var library = try load()
        try library.select(id)
        try write(library)
    }

    func remove(_ id: UUID) throws {
        var library = try load()
        guard let profile = library.profiles.first(where: { $0.id == id }) else { return }
        let previous = library
        library.remove(id)
        try write(library)
        let status = SecItemDelete(credentialKey(for: profile) as CFDictionary)
        if status != errSecItemNotFound && status != errSecSuccess {
            try write(previous)
            try Self.check(status)
        }
    }

    private func write(_ library: ServerLibrary) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try PersistedConfiguration.ensureSupportedVersion(Data(contentsOf: file))
        }
        try PersistedConfiguration.encodeLibrary(library).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func save(_ profile: Profile, credentials: Credentials) throws {
        var library = try load()
        if FileManager.default.fileExists(atPath: file.path) {
            try PersistedConfiguration.ensureSupportedVersion(Data(contentsOf: file))
        }
        if let existing = try credentialData(for: profile) {
            try PersistedConfiguration.ensureSupportedVersion(existing)
        }
        let secret = try PersistedConfiguration.encodeCredentials(credentials)
        let key = credentialKey(for: profile)
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = secret
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else { try Self.check(status) }
        library.upsert(profile)
        try write(library)
    }

    func credentials(for profile: Profile) throws -> Credentials {
        guard let data = try credentialData(for: profile) else { return Credentials() }
        return try PersistedConfiguration.decodeCredentials(data)
    }

    /// Removes obsolete plaintext worker files without blocking recovery when deletion is denied.
    private func removeLegacySessionFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func credentialKey(for profile: Profile) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Hy2UI.credentials",
         kSecAttrAccount as String: profile.id.uuidString]
    }

    private func credentialData(for profile: Profile) throws -> Data? {
        var query = credentialKey(for: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        guard let data = result as? Data else { throw ConfigurationError.invalid("钥匙串中的凭据无法读取。") }
        return data
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ConfigurationError.invalid("钥匙串：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}
