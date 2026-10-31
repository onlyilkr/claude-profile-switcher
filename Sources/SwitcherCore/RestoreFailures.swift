import Foundation

/// Accounts whose pin store could not be put back after a failed write, each with the folder that holds the backup.
/// Kept in a file, so the menu bar app and the command line both refuse to open such an account until its storage
/// reads clean again: Claude starting on half-restored data could reset it.
final class RestoreFailures {
    private let file: URL
    private let lockFile: URL
    /// What this process has seen fail, so it keeps refusing the account even when the file could not be saved.
    private var memory: [String: String] = [:]
    private let memoryLock = NSLock()

    init(file: URL) {
        self.file = file
        self.lockFile = URL(fileURLWithPath: file.path + ".lock")
    }

    /// Profile id (lowercased) to backup folder path. Reads are lock-free: the file is replaced atomically.
    /// A damaged file reads as empty, like `claims.json`.
    /// The file's entries plus those this process remembers.
    var all: [String: String] {
        memoryLock.lock(); let mine = memory; memoryLock.unlock()
        return onDisk.merging(mine) { disk, _ in disk }
    }

    private var onDisk: [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func backup(for id: String) -> String? { all[id.lowercased()] }

    /// Remembered in this process either way. False when the file could not be saved (the caller logs it).
    @discardableResult
    func set(_ id: String, backup: String) -> Bool {
        memoryLock.lock(); memory[id.lowercased()] = backup; memoryLock.unlock()
        return update { $0[id.lowercased()] = backup }
    }

    @discardableResult
    func clear(_ id: String) -> Bool {
        memoryLock.lock(); memory[id.lowercased()] = nil; memoryLock.unlock()
        return update { $0[id.lowercased()] = nil }
    }

    private func update(_ change: (inout [String: String]) -> Void) -> Bool {
        (try? FileLock.exclusively(lockFile) {
            var current = onDisk
            change(&current)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { try FileLock.writePrivately(try encoder.encode(current), to: file) } catch { return false }
            return true
        }) ?? false
    }
}
