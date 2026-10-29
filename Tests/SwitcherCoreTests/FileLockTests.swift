import XCTest
@testable import SwitcherCore

final class FileLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testExclusivelySerialisesWritersOnOneFile() throws {
        let lock = dir.appendingPathComponent("counter.lock")
        let counter = dir.appendingPathComponent("counter.txt")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<200 {
                    try? FileLock.exclusively(lock) {
                        let n = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0
                        try? String(n + 1).write(to: counter, atomically: true, encoding: .utf8)
                    }
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "400")
    }

    func testLockFileIsPrivate() throws {
        let lock = dir.appendingPathComponent("sub/private.lock")
        try FileLock.exclusively(lock) {}
        let mode = try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: lock.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
    }

    func testExclusivelyRethrowsTheBodysError() {
        let lock = dir.appendingPathComponent("err.lock")
        XCTAssertThrowsError(try FileLock.exclusively(lock) { throw SwitcherError("x") }) {
            XCTAssertEqual($0 as? SwitcherError, SwitcherError("x"))
        }
    }
}
