import Foundation
import Darwin

/// Starts the root-only local TUN service or restores its fixed DNS recovery journal.
@main
struct LocalTunHelperMain {
    static func main() {
        do {
            try TrustedInstallation.requireRoot()
            umask(0o077)
            try TrustedInstallation.requireSafeDirectory(LocalTunWire.installationDirectory)
            let lease = try HelperInstanceLock()
            defer { lease.release() }
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--recover-dns"] {
                try PrivilegedDNS().restore()
                return
            }
            guard arguments.count == 2, arguments[0] == "--allowed-uid",
                  let value = UInt32(arguments[1]), value > 0, value < UInt32.max else {
                throw HelperFailure("使用 --allowed-uid 指定唯一允许连接的本地用户。")
            }
            let termination = HelperTermination()
            termination.monitor()
            try LocalTunServer(allowedUID: uid_t(value), termination: termination).run()
        } catch {
            HelperDiagnostics.record(HelperFailure.safeFailure(error))
            exit(1)
        }
    }
}
