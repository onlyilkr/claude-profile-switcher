import Foundation

/// Parsed contents of small files Claude rewrites (config.json, plan-usage-history.json),
/// kept until the file's modification date changes. The panel refreshes every 1.5 s while
/// open; without this it would parse every profile's files each time.
enum FileCache {
    private static var entries: [String: (modified: Date, value: Any?)] = [:]
    private static let lock = NSLock()

    static func value<T>(_ url: URL, parse: (Data) -> T?) -> T? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries[url.path], hit.modified == modified { return hit.value as? T }
        let value = (try? Data(contentsOf: url)).flatMap(parse)
        entries[url.path] = (modified, value)
        return value
    }
}
