import Foundation

/// Owns one experimental C ABI handle and converts its bounded packet and status results.
final class RustPacketCore: ExperimentalPacketCore {
    private var handle: OpaquePointer?
    private var buffer = [UInt8](repeating: 0, count: 65_535)

    init(configuration: Data) throws {
        guard hy2_packet_bridge_version() == 1 else { throw ExperimentalPacketError.bridgeVersion }
        guard let object = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ExperimentalPacketError.invalidConfiguration
        }
        guard (object["lazy"] as? Bool) != true else { throw ExperimentalPacketError.unsupportedLazyConfiguration }
        var created: OpaquePointer?
        let result = configuration.withUnsafeBytes { bytes in
            hy2_packet_bridge_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &created)
        }
        guard result == Int32(HY2_PACKET_OK.rawValue) else { throw ExperimentalPacketError.bridgeOperation(result) }
        guard let created else { throw ExperimentalPacketError.invalidCoreStatus }
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

    func status() throws -> ExperimentalCoreStatus {
        guard let handle else { throw ExperimentalPacketError.invalidState }
        var bytes = [UInt8](repeating: 0, count: 8192)
        var length = 0
        var result = bytes.withUnsafeMutableBufferPointer {
            hy2_packet_bridge_status(handle, $0.baseAddress, $0.count, &length)
        }
        if result == Int32(HY2_PACKET_BUFFER_TOO_SMALL.rawValue) {
            guard length > 0, length <= 65_536 else { throw ExperimentalPacketError.invalidCoreStatus }
            bytes = [UInt8](repeating: 0, count: length)
            result = bytes.withUnsafeMutableBufferPointer {
                hy2_packet_bridge_status(handle, $0.baseAddress, $0.count, &length)
            }
        }
        guard result == Int32(HY2_PACKET_OK.rawValue), length <= bytes.count else {
            throw ExperimentalPacketError.bridgeOperation(result)
        }
        let snapshot: PacketBridgeSnapshot
        do { snapshot = try JSONDecoder().decode(PacketBridgeSnapshot.self, from: Data(bytes.prefix(length))) }
        catch { throw ExperimentalPacketError.invalidCoreStatus }
        guard snapshot.schemaVersion == 1 else { throw ExperimentalPacketError.invalidCoreStatus }
        return ExperimentalCoreStatus(stackReady: snapshot.client.readyComponents.contains("tun"),
                                      connection: snapshot.client.connection, worker: snapshot.worker,
                                      errorCode: snapshot.client.errorCode ?? snapshot.client.connectionErrorCode)
    }

    func write(_ packet: Data) throws -> ExperimentalPacketAdmission {
        guard let handle else { throw ExperimentalPacketError.invalidState }
        let result = packet.withUnsafeBytes { bytes in
            hy2_packet_bridge_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        switch result {
        case Int32(HY2_PACKET_OK.rawValue): return .accepted
        case Int32(HY2_PACKET_FULL.rawValue): return .full
        case Int32(HY2_PACKET_INVALID_PACKET.rawValue): throw ExperimentalPacketError.invalidPacket
        default: throw ExperimentalPacketError.bridgeOperation(result)
        }
    }

    func read() throws -> Data? {
        guard let handle else { throw ExperimentalPacketError.invalidState }
        var length = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            hy2_packet_bridge_read(handle, $0.baseAddress, $0.count, &length)
        }
        switch result {
        case Int32(HY2_PACKET_OK.rawValue):
            guard length > 0, length <= buffer.count else { throw ExperimentalPacketError.invalidPacket }
            return Data(buffer.prefix(length))
        case Int32(HY2_PACKET_EMPTY.rawValue): return nil
        case Int32(HY2_PACKET_CLOSED.rawValue): throw ExperimentalPacketError.outputClosed
        default: throw ExperimentalPacketError.bridgeOperation(result)
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
        guard result == Int32(HY2_PACKET_OK.rawValue) else { throw ExperimentalPacketError.bridgeOperation(result) }
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
