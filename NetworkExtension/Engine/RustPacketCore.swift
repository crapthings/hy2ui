import Foundation

/// Owns one versioned packet C ABI handle and converts its bounded packet and status results.
final class RustPacketCore: PacketCore {
    private var handle: OpaquePointer?
    private var buffer = [UInt8](repeating: 0, count: 65_535)

    init(configuration: Data) throws {
        guard hy2_packet_bridge_version() == 1 else { throw PacketEngineError.bridgeVersion }
        guard let object = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw PacketEngineError.invalidConfiguration
        }
        guard (object["lazy"] as? Bool) != true else { throw PacketEngineError.unsupportedLazyConfiguration }
        var created: OpaquePointer?
        let result = configuration.withUnsafeBytes { bytes in
            hy2_packet_bridge_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &created)
        }
        guard result == Int32(HY2_PACKET_OK.rawValue) else { throw PacketEngineError.bridgeOperation(result) }
        guard let created else { throw PacketEngineError.invalidCoreStatus }
        handle = created
    }

    deinit {
        if let orphan = handle {
            // Schedule cleanup without blocking the thread that released the core.
            DispatchQueue.global(qos: .utility).async {
                _ = hy2_packet_bridge_shutdown(orphan)
                _ = hy2_packet_bridge_destroy(orphan)
            }
        }
    }

    func status() throws -> PacketCoreStatus {
        guard let handle else { throw PacketEngineError.invalidState }
        var bytes = [UInt8](repeating: 0, count: 8192)
        var length = 0
        var result = bytes.withUnsafeMutableBufferPointer {
            hy2_packet_bridge_status(handle, $0.baseAddress, $0.count, &length)
        }
        if result == Int32(HY2_PACKET_BUFFER_TOO_SMALL.rawValue) {
            guard length > 0, length <= 65_536 else { throw PacketEngineError.invalidCoreStatus }
            bytes = [UInt8](repeating: 0, count: length)
            result = bytes.withUnsafeMutableBufferPointer {
                hy2_packet_bridge_status(handle, $0.baseAddress, $0.count, &length)
            }
        }
        guard result == Int32(HY2_PACKET_OK.rawValue), length <= bytes.count else {
            throw PacketEngineError.bridgeOperation(result)
        }
        let snapshot: PacketBridgeSnapshot
        do { snapshot = try JSONDecoder().decode(PacketBridgeSnapshot.self, from: Data(bytes.prefix(length))) }
        catch { throw PacketEngineError.invalidCoreStatus }
        guard snapshot.schemaVersion == 1 else { throw PacketEngineError.invalidCoreStatus }
        return PacketCoreStatus(stackReady: snapshot.client.readyComponents.contains("tun"),
                                      connection: snapshot.client.connection, worker: snapshot.worker,
                                      errorCode: snapshot.client.errorCode ?? snapshot.client.connectionErrorCode)
    }

    func write(_ packet: Data) throws -> PacketAdmission {
        guard let handle else { throw PacketEngineError.invalidState }
        let result = packet.withUnsafeBytes { bytes in
            hy2_packet_bridge_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        switch result {
        case Int32(HY2_PACKET_OK.rawValue): return .accepted
        case Int32(HY2_PACKET_FULL.rawValue): return .full
        case Int32(HY2_PACKET_INVALID_PACKET.rawValue): throw PacketEngineError.invalidPacket
        default: throw PacketEngineError.bridgeOperation(result)
        }
    }

    func read() throws -> Data? {
        guard let handle else { throw PacketEngineError.invalidState }
        var length = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            hy2_packet_bridge_read(handle, $0.baseAddress, $0.count, &length)
        }
        switch result {
        case Int32(HY2_PACKET_OK.rawValue):
            guard length > 0, length <= buffer.count else { throw PacketEngineError.invalidPacket }
            return Data(buffer.prefix(length))
        case Int32(HY2_PACKET_EMPTY.rawValue): return nil
        case Int32(HY2_PACKET_CLOSED.rawValue): throw PacketEngineError.outputClosed
        default: throw PacketEngineError.bridgeOperation(result)
        }
    }

    func shutdown() {
        guard let handle else { return }
        _ = hy2_packet_bridge_shutdown(handle)
    }

    func destroy() throws {
        guard let handle else { return }
        self.handle = nil
        let result = hy2_packet_bridge_destroy(handle)
        guard result == Int32(HY2_PACKET_OK.rawValue) else { throw PacketEngineError.bridgeOperation(result) }
    }
}

/// Decodes the versioned, credential-free portion of the Rust bridge status snapshot.
private struct PacketBridgeSnapshot: Decodable {
    struct Client: Decodable {
        let connection: String
        let readyComponents: [String]
        let errorCode: String?
        let connectionErrorCode: String?
        enum CodingKeys: String, CodingKey {
            case connection
            case readyComponents = "ready_components"
            case errorCode = "error_code"
            case connectionErrorCode = "connection_error_code"
        }
    }
    let schemaVersion: Int
    let client: Client
    let worker: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case client, worker
    }
}
