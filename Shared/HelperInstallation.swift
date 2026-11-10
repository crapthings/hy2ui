import Foundation

/// Identifies the privileged background operation explicitly requested by the user.
public enum HelperInstallationOperation: String, Sendable {
    case install, uninstall
}

/// Records the immutable executable hashes and user authorized by a completed installation.
public struct HelperInstallationManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let helperSHA256: String
    public let workerSHA256: String
    public let allowedUID: UInt32

    public init(version: Int = 1, helperSHA256: String, workerSHA256: String, allowedUID: UInt32) {
        self.version = version
        self.helperSHA256 = helperSHA256
        self.workerSHA256 = workerSHA256
        self.allowedUID = allowedUID
    }

    public func validate() throws {
        guard version == 1, Self.validDigest(helperSHA256), Self.validDigest(workerSHA256),
              allowedUID > 0, allowedUID < UInt32.max else { throw HelperInstallationError.invalidManifest }
    }

    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Describes a failed or cancelled administrator operation without handling administrator credentials.
public enum HelperInstallationError: LocalizedError {
    case invalidManifest, invalidPayload, invalidUser, invalidApplication, applicationChanged, cancelled, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "后台安装记录无效，请重新安装后台。"
        case .invalidPayload: "应用中的后台安装程序损坏，请重新构建或下载应用。"
        case .invalidUser: "请以普通用户身份启动 Hy2UI，安装时再进行管理员授权。"
        case .invalidApplication: "应用签名或内置后台程序校验失败，请重新构建或下载应用。"
        case .applicationChanged: "应用已更新，请退出后重新打开，再安装后台。"
        case .cancelled: "管理员授权已取消，后台未执行新的安装或卸载操作。"
        case let .failed(message): message
        }
    }
}

/// Constructs a fixed administrator operation using shell-safe arguments and immutable installer source.
public enum HelperInstallationCommand {
    public static let cancellationMarker = "HY2UI_AUTHORIZATION_CANCELLED"

    public static func authorizationScript(operation: HelperInstallationOperation, installerSource: String,
                                           appPath: String, manifest: HelperInstallationManifest) throws -> String {
        try manifest.validate()
        guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"), !appPath.contains("\0") else {
            throw HelperInstallationError.invalidApplication
        }
        guard installerSource.hasPrefix("#!/bin/bash\n"), installerSource.utf8.count <= 65_536,
              !installerSource.contains("\0") else { throw HelperInstallationError.invalidPayload }
        var arguments = ["/usr/bin/env", "-i", "SUDO_UID=\(manifest.allowedUID)"]
        if operation == .install {
            arguments += ["HY2_EXPECTED_HELPER_SHA256=\(manifest.helperSHA256)", "HY2_EXPECTED_WORKER_SHA256=\(manifest.workerSHA256)"]
        }
        arguments += ["/bin/bash", "-c", installerSource, "hy2ui-embedded-installer"]
        if operation == .install { arguments.append(appPath) }
        let command = arguments.map(shellQuote).joined(separator: " ")
        return """
        try
            do shell script \(appleScriptLiteral(command)) with administrator privileges
        on error messageText number errorNumber
            if errorNumber is -128 then
                return "\(cancellationMarker)"
            end if
            error messageText number errorNumber
        end try
        """
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
