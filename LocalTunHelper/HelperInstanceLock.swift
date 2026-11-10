import Foundation
import Darwin

/// Prevents overlapping helper or recovery processes from changing the same DNS journal.
final class HelperInstanceLock {
    private var descriptor: Int32 = -1

    init() throws {
        let path = LocalTunWire.installationDirectory + "/helper.lock"
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HelperFailure("无法建立特权服务锁。") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            release()
            throw HelperFailure("已有本地增强模式服务运行，或服务锁权限无效。")
        }
    }

    deinit { release() }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
