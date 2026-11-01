import XCTest
@testable import SwitcherCore

final class LevelDBWriterTests: XCTestCase {
    private var folder: URL!
    private var fx: LevelDBFixture!
    private let k = Data("p".utf8), v = Data("value".utf8)

    override func setUpWithError() throws {
        folder = LevelDBFixture.tempFolder()
        fx = try LevelDBFixture(folder: folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var writer: LevelDBWriter { LevelDBWriter(folder: folder) }
    private var reader: LevelDBReader { LevelDBReader(folder: folder) }
    private var logURL: URL { folder.appendingPathComponent("000008.log") }

    /// Log 8 holding one batch at `seq`, with a MANIFEST that names it current.
    private func makeDatabase(seq: UInt64 = 500, value: Data = Data("old".utf8)) throws {
        try fx.writeLog(number: 8, batches: [.init(sequence: seq, ops: [(k, value)])])
        try fx.writeManifest(logNumber: 8, lastSequence: seq - 1, liveTables: [])
        try Data().write(to: folder.appendingPathComponent("LOCK"))
    }

    func testAppendThenReadBack() throws {
        try makeDatabase()
        let seq = try writer.append([(k, v)])
        XCTAssertEqual(try reader.newest(k), LevelDBEntry(key: k, sequence: seq, isPut: true, value: v))
    }

    func testRefusesSeveralLiveLogs() throws {
        try makeDatabase()
        try fx.writeLog(number: 9, batches: [.init(sequence: 600, ops: [(k, Data("newer".utf8))])])
        let before = try Data(contentsOf: logURL)
        XCTAssertThrowsError(try writer.append([(k, v)])) { XCTAssertEqual(($0 as? SwitcherError)?.logReason, "leveldb several live logs") }
        XCTAssertEqual(try Data(contentsOf: logURL), before)
    }

    func testAnOlderLogDoesNotCountAsLive() throws {
        try makeDatabase()
        try fx.writeLog(number: 7, batches: [.init(sequence: 400, ops: [(k, Data("older".utf8))])])
        XCTAssertNoThrow(try writer.append([(k, v)]))
    }

    func testSequenceIsAboveEverything() throws {
        try makeDatabase(seq: 500)
        XCTAssertEqual(try writer.append([(k, v)]), 501)
    }

    func testSeveralPutsGetConsecutiveSequences() throws {
        try makeDatabase(seq: 10)
        let k2 = Data("q".utf8)
        XCTAssertEqual(try writer.append([(k, v), (k2, v)]), 11)
        XCTAssertEqual(try reader.newest(k)?.sequence, 11)
        XCTAssertEqual(try reader.newest(k2)?.sequence, 12)
    }

    /// Pads the log so exactly `left` bytes remain in its first block.
    private func padLog(leaving left: Int) throws {
        let payload = 32768 - left - 7
        let valueLength = payload - 12 - 3 - 3   // 12 header, op + 2-byte key prefix + 3-byte length varint
        try makeDatabase(value: Data(repeating: 7, count: valueLength))
        XCTAssertEqual(try Data(contentsOf: logURL).count, 32768 - left)
    }

    func testAppendNearBlockBoundaryFragments() throws {
        try padLog(leaving: 20)
        let big = Data((0..<70_000).map { UInt8($0 % 251) })
        _ = try writer.append([(k, big)])
        XCTAssertEqual(try reader.newest(k)?.value, big)
        XCTAssertNoThrow(try LevelDBReader(folder: folder).maxSequence())
    }

    func testAppendPadsWhenFewerThanHeaderBytesRemain() throws {
        try padLog(leaving: 3)
        _ = try writer.append([(k, v)])
        XCTAssertEqual(try reader.newest(k)?.value, v)
        let bytes = try Data(contentsOf: logURL)
        XCTAssertEqual(Array(bytes[32765..<32768]), [0, 0, 0])
    }

    func testAppendAfterFullPaddingAtBlockEnd() throws {
        try padLog(leaving: 3)
        var bytes = try Data(contentsOf: logURL)
        bytes.append(contentsOf: [0, 0, 0])   // padding already written by a previous writer
        try bytes.write(to: logURL)
        _ = try writer.append([(k, v)])
        XCTAssertEqual(try reader.newest(k)?.value, v)
    }

    func testRefusesWhenLockIsHeld() throws {
        try makeDatabase()
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "python3 not available")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: python)
        helper.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(10)",
                            folder.appendingPathComponent("LOCK").path]
        let out = Pipe()
        helper.standardOutput = out
        try helper.run()
        defer { helper.terminate(); helper.waitUntilExit() }
        XCTAssertEqual(String(data: out.fileHandleForReading.availableData, encoding: .utf8), "locked\n")

        var ran = false
        XCTAssertThrowsError(try LevelDBLock.withExclusive(folder) { ran = true }) { error in
            XCTAssertEqual((error as? SwitcherError)?.logReason, "store is locked")
        }
        XCTAssertFalse(ran)
    }

    func testLockIsReleasedAfterBody() throws {
        try makeDatabase()
        XCTAssertEqual(try LevelDBLock.withExclusive(folder) { 1 }, 1)
        XCTAssertEqual(try LevelDBLock.withExclusive(folder) { 2 }, 2)
    }

    func testRefusesDirtyLog() throws {
        try makeDatabase()
        var bytes = try Data(contentsOf: logURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: logURL)
        let before = bytes
        XCTAssertThrowsError(try writer.append([(k, v)]))
        XCTAssertEqual(try Data(contentsOf: logURL), before)
    }

    func testRefusesTornTail() throws {
        try fx.writeLog(number: 8, batches: [.init(sequence: 5, ops: [(k, v)])], tearLastRecord: true)
        try fx.writeManifest(logNumber: 8, lastSequence: 4, liveTables: [])
        XCTAssertThrowsError(try writer.append([(k, v)])) { error in
            XCTAssertEqual((error as? SwitcherError)?.logReason, "leveldb read failed")
        }
    }

    func testRefusesTrailingBytesAfterLastRecord() throws {
        try makeDatabase()
        var bytes = try Data(contentsOf: logURL)
        bytes.append(contentsOf: [0, 0, 0])   // zero bytes mid-block: a new record there would be unreadable
        try bytes.write(to: logURL)
        XCTAssertThrowsError(try writer.append([(k, v)])) { error in
            XCTAssertEqual((error as? SwitcherError)?.logReason, "leveldb log not clean")
        }
        XCTAssertEqual(try Data(contentsOf: logURL), bytes)
    }

    func testRefusesWhenManifestLogIsMissing() throws {
        try fx.writeManifest(logNumber: 8, lastSequence: 4, liveTables: [])
        XCTAssertThrowsError(try writer.append([(k, v)])) { error in
            XCTAssertEqual((error as? SwitcherError)?.logReason, "leveldb current log missing")
        }
    }

    func testRefusesEmptyPutList() throws {
        try makeDatabase()
        let before = try Data(contentsOf: logURL)
        XCTAssertThrowsError(try writer.append([]))
        XCTAssertEqual(try Data(contentsOf: logURL), before)
    }

    func testRefusesSequenceAtTheTypeLimit() throws {
        try makeDatabase(seq: (1 << 56) - 1)
        XCTAssertThrowsError(try writer.append([(k, v)]))
    }
}
