import Foundation
import CryptoKit
import Security
import Darwin

/// Identifies the two bundled executables and user approved by one installer transaction.
struct HelperInstallationSnapshot: Sendable {
    let application: URL
    let manifest: HelperInstallationManifest
}

/// Describes the installed background component independently from tunnel connection state.
enum HelperInstallationStatus: Equatable, Sendable {
    case checking, notInstalled, current, updateAvailable, legacy, otherUser, damaged
    var title: String {
        switch self {
        case .checking: "正在检查后台…"
        case .notInstalled: "尚未安装后台"
        case .current: "后台已安装"
        case .updateAvailable: "后台有可用更新"
        case .legacy: "发现旧版后台"
        case .otherUser: "后台已安装给其他账户"
        case .damaged: "后台需要修复"
        }
    }
    var isInstalled: Bool { self != .notInstalled && self != .checking }
}

/// Verifies bundled code and reads root-owned installation records without changing system state.
enum HelperInstallationProbe {
    static let manifestName = "installation.plist"
    static let helperName = "hy2-local-tun-helper"
    static let workerName = "hy2-tun-worker"

    static func snapshot(application: URL) throws -> HelperInstallationSnapshot {
        guard getuid() > 0 else { throw HelperInstallationError.invalidUser }
        try verifyRunningApplication(application)
        let directory = application.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let helper = directory.appendingPathComponent(helperName)
        let worker = directory.appendingPathComponent(workerName)
        for executable in [helper, worker] {
            let resource = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                  resource.isExecutable == true else { throw HelperInstallationError.invalidApplication }
            try verifyStaticCode(executable)
        }
        let manifest = HelperInstallationManifest(helperSHA256: try digest(helper), workerSHA256: try digest(worker), allowedUID: getuid())
        // Check resource integrity again after hashing so a changed bundle is never silently installed.
        try verifyRunningApplication(application)
        return HelperInstallationSnapshot(application: application, manifest: manifest)
    }

    static func status(application: URL) -> HelperInstallationStatus {
        let directory = URL(fileURLWithPath: LocalTunWire.installationDirectory)
        let helper = directory.appendingPathComponent(helperName)
        let worker = directory.appendingPathComponent(workerName)
        let manifestURL = directory.appendingPathComponent(manifestName)
        let hasHelper = FileManager.default.fileExists(atPath: helper.path)
        let hasWorker = FileManager.default.fileExists(atPath: worker.path)
        guard hasHelper || hasWorker || FileManager.default.fileExists(atPath: manifestURL.path) else { return .notInstalled }
        do {
            try requireRootOwned(directory, directory: true)
            try requireRootOwned(helper, directory: false)
            try requireRootOwned(worker, directory: false)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .legacy }
            try requireRootOwned(manifestURL, directory: false)
            let metadata = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = metadata.fileSize, size <= 8192 else { return .damaged }
            let installed = try PropertyListDecoder().decode(HelperInstallationManifest.self, from: Data(contentsOf: manifestURL))
            try installed.validate()
            if installed.allowedUID != getuid() { return .otherUser }
            guard try digest(helper) == installed.helperSHA256, try digest(worker) == installed.workerSHA256 else { return .damaged }
            let bundled = application.appendingPathComponent("Contents/Helpers", isDirectory: true)
            let expectedHelper = try digest(bundled.appendingPathComponent(helperName))
            let expectedWorker = try digest(bundled.appendingPathComponent(workerName))
            return installed.helperSHA256 == expectedHelper && installed.workerSHA256 == expectedWorker ? .current : .updateAvailable
        } catch { return .damaged }
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireRootOwned(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0,
              info.st_mode & 0o022 == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw HelperInstallationError.invalidManifest
        }
    }

    private static func verifyRunningApplication(_ application: URL) throws {
        guard application.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath() else {
            throw HelperInstallationError.invalidApplication
        }
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else {
            throw HelperInstallationError.invalidApplication
        }
        let result = SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        if result == errSecCSStaticCodeChanged { throw HelperInstallationError.applicationChanged }
        guard result == errSecSuccess else { throw HelperInstallationError.invalidApplication }
        try verifyStaticCode(application)
    }

    private static func verifyStaticCode(_ location: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(location as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw HelperInstallationError.invalidApplication
        }
    }
}
