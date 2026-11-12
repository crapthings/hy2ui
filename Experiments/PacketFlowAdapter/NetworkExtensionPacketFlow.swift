import Foundation
import NetworkExtension

/// Maps the system packet-flow API onto the independently testable adapter contract.
final class NetworkExtensionPacketFlow: ExperimentalPacketFlow {
    private let flow: NEPacketTunnelFlow

    init(_ flow: NEPacketTunnelFlow) { self.flow = flow }

    func readPackets(completion: @escaping ([Data], [Int32]) -> Void) {
        flow.readPackets { packets, protocols in
            completion(packets, protocols.map(\.int32Value))
        }
    }

    func writePackets(_ packets: [Data], families: [Int32]) -> Bool {
        flow.writePackets(packets, withProtocols: families.map { NSNumber(value: $0) })
    }
}
