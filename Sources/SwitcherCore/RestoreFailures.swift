import Foundation

/// Accounts whose pin store could not be put back after a failed write, each with the folder that holds the backup.
/// Kept in a file, so the menu bar app and the command line both refuse to open such an account until its storage
/// reads clean again: Claude starting on half-restored data could reset it.
final class RestoreFailures {
    private let file: URL
    private let lockFile: URL

    init(file: URL) {
        self.file = file
        self.lockFile = URL(fileURLWithPath: file.path + ".lock")
    }

    /// Profile id (lowercased) to backup folder path. Reads are lock-free: the file is replaced atomically.
    /// A damaged file reads as empty, like `claims.json`.
    var all: [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func backup(for id: String) -> String? { all[id.lowercased()] }

    /// False when the marker could not be saved (the caller logs it).
    @discardableResult
    func set(_ id: String, backup: String) -> Bool { update { $0[id.lowercased()] = backup } }

    @discardableResult
    func clear(_ id: String) -> Bool { update { $0[id.lowercased()] = nil } }

    private func update(_ change: (inout [String: String]) -> Void) -> Bool {
        (try? FileLock.exclusively(lockFile) {
            var current = all
            change(&current)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { try encoder.encode(current).write(to: file, options: .atomic) } catch { return false }
            chmod(file.path, 0o600)
            return true
        }) ?? false
    }
}
