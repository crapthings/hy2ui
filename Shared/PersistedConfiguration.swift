import Foundation

/// Encodes versioned settings while accepting legacy payloads and rejecting unsupported future schemas.
public enum PersistedConfiguration {
    private static let currentVersion = 1

    public static func encodeLibrary(_ library: ServerLibrary) throws -> Data {
        try encode(library)
    }

    public static func decodeLibrary(_ data: Data) throws -> ServerLibrary {
        try decode(data, as: ServerLibrary.self)
    }

    public static func encodeProfile(_ profile: Profile) throws -> Data {
        try encode(profile)
    }

    public static func decodeProfile(_ data: Data) throws -> Profile {
        try decode(data, as: Profile.self)
    }

    public static func encodeCredentials(_ credentials: Credentials) throws -> Data {
        try encode(credentials)
    }

    public static func decodeCredentials(_ data: Data) throws -> Credentials {
        try decode(data, as: Credentials.self)
    }

    /// Prevents saving over a future schema while allowing explicit replacement of malformed legacy data.
    public static func ensureSupportedVersion(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] != nil else { return }
        let header = try JSONDecoder().decode(PersistenceVersion.self, from: data)
        try requireSupported(header.version)
    }

    private static func encode<Value: Codable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(PersistenceEnvelope(version: currentVersion, value: value))
    }

    private static func decode<Value: Codable>(_ data: Data, as type: Value.Type) throws -> Value {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["version"] != nil {
            let header = try JSONDecoder().decode(PersistenceVersion.self, from: data)
            try requireSupported(header.version)
            return try JSONDecoder().decode(PersistenceEnvelope<Value>.self, from: data).value
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func requireSupported(_ version: Int) throws {
        guard version == currentVersion else {
            throw ConfigurationError.invalid("配置版本 \(version) 不受当前应用支持，请使用兼容的应用版本。")
        }
    }
}

/// Reads a payload's schema version before decoding its version-specific contents.
private struct PersistenceVersion: Decodable {
    let version: Int
}

/// Wraps one persisted value in an explicit schema version shared by file and Keychain storage.
private struct PersistenceEnvelope<Value: Codable>: Codable {
    let version: Int
    let value: Value
}
