import Foundation

/// An exclusive `flock` on a sidecar lock file, so the app and the command line never lose each other's
/// read-modify-write of a shared file. Callers that also need in-process exclusion keep their own lock.
public enum FileLock {
    public static func exclusively<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw SwitcherError(String(cString: strerror(errno))) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw SwitcherError(String(cString: strerror(errno))) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

extension FileLock {
    /// Replaces `file` atomically with `data`, the temp file created owner-only (0600) so the content is never
    /// readable by others, not even between the write and the rename.
    static func writePrivately(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SwitcherError(String(cString: strerror(errno)))
        }
        if rename(temp.path, file.path) != 0 {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw SwitcherError(message)
        }
    }
}
