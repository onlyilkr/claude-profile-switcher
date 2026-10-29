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
