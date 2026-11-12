import Foundation

/// Exposes packet flow operations independently of the system Network Extension object.
protocol ExperimentalPacketFlow: AnyObject {
    func readPackets(completion: @escaping ([Data], [Int32]) -> Void)
    func writePackets(_ packets: [Data], families: [Int32]) -> Bool
}

/// Represents a bounded packet admission result from the Rust core.
enum ExperimentalPacketAdmission: Equatable {
    case accepted
    case full
}

/// Captures only the core state needed for packet adapter lifecycle decisions.
struct ExperimentalCoreStatus {
    let stackReady: Bool
    let connection: String
    let worker: String
    let errorCode: String?
}

/// Isolates the single-owner Rust handle behind operations serialized by the adapter.
protocol ExperimentalPacketCore: AnyObject {
    func status() throws -> ExperimentalCoreStatus
    func write(_ packet: Data) throws -> ExperimentalPacketAdmission
    func read() throws -> Data?
    func shutdown()
    func destroy() throws
}

/// Describes a packet adapter failure without including configuration or credentials.
enum ExperimentalPacketError: Error, Equatable {
    case busy
    case invalidState
    case cancelled
    case startupTimedOut
    case coreFailed(String?)
    case invalidCoreStatus
    case invalidPacket
    case invalidBatch
    case packetBacklogExceeded
    case outputClosed
    case outputRejected
    case bridgeVersion
    case bridgeOperation(Int32)
    case invalidConfiguration
    case unsupportedLazyConfiguration
}
