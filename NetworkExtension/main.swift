import Foundation
import NetworkExtension

// Starts only the system-managed provider process; it does not create or activate a VPN.
NEProvider.startSystemExtensionMode()
dispatchMain()
