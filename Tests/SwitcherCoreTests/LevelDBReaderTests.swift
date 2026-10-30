import XCTest
@testable import SwitcherCore

final class LevelDBReaderTests: XCTestCase {
    private var folder: URL!
    private var fx: LevelDBFixture!

    override func setUpWithError() throws {
        folder = LevelDBFixture.tempFolder()
        fx = try LevelDBFixture(folder: folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func d(_ s: String) -> Data { Data(s.utf8) }
    private typealias R = LevelDBFixture.Record
    private typealias B = LevelDBFixture.Batch

    func testNewestWinsAcrossTableAndLog() throws {
        let k = d("k")
        try fx.writeTable(number: 5, records: [R(k, d("v1"), seq: 5)])
        try fx.writeLog(number: 8, batches: [B(sequence: 9, ops: [(k, d("v2"))])])
        try fx.writeManifest(logNumber: 8, lastSequence: 9, liveTables: [5])
        let e = try LevelDBReader(folder: folder).newest(k)
        XCTAssertEqual(e?.value, d("v2"))
        XCTAssertEqual(e?.sequence, 9)
    }

    func testDeletionInLogHidesTableValue() throws {
        let k = d("k")
        try fx.writeTable(number: 5, records: [R(k, d("v1"), seq: 5)])
        try fx.writeLog(number: 8, batches: [B(sequence: 6, ops: [(k, nil)])])
        try fx.writeManifest(logNumber: 8, lastSequence: 6, liveTables: [5])
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(k)?.isPut, false)
    }

    func testSnappyCompressedTableBlockIsRead() throws {
        let k = Data([0x5F]) + d("https://claude.ai") + Data([0, 1]) + d("name"), v = Data(repeating: 0xAB, count: 300)
        try fx.writeTable(number: 5, records: [R(k, v, seq: 2), R(d("other"), d("x"), seq: 3)], compression: .snappy)
        try fx.writeManifest(logNumber: 8, lastSequence: 3, liveTables: [5])
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(k)?.value, v)
    }

    func testPrefixCompressedKeysAcrossBlocksAreRead() throws {
        let records = (0..<50).map { R(d(String(format: "key-%03d", $0)), d("v\($0)"), seq: UInt64($0 + 1)) }
        try fx.writeTable(number: 5, records: records, entriesPerBlock: 7)
        try fx.writeManifest(logNumber: 8, lastSequence: 50, liveTables: [5])
        let all = try LevelDBReader(folder: folder).entries { _ in true }
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.map(\.key), records.map(\.key))
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(d("key-042"))?.value, d("v42"))
    }

    func testObsoleteTableNotInManifestIsIgnored() throws {
        let k = d("k")
        try fx.writeTable(number: 9, records: [R(k, d("old"), seq: 99)])
        try fx.writeTable(number: 10, records: [R(k, d("current"), seq: 7)])
        try fx.writeManifest(logNumber: 12, lastSequence: 7, liveTables: [10], deletedTables: [9])
        XCTAssertEqual(try LevelDBReader(folder: folder).manifest().liveTables, [10])
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(k)?.value, d("current"))
    }

    func testLogsOlderThanManifestLogNumberAreIgnored() throws {
        let k = d("k")
        try fx.writeLog(number: 3, batches: [B(sequence: 50, ops: [(k, d("stale"))])])
        try fx.writeLog(number: 8, batches: [B(sequence: 4, ops: [(k, d("fresh"))])])
        try fx.writeManifest(logNumber: 8, lastSequence: 4, liveTables: [])
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(k)?.value, d("fresh"))
    }

    func testPrevLogNumberIsStillRead() throws {
        try fx.writeLog(number: 7, batches: [B(sequence: 4, ops: [(d("a"), d("1"))])])
        try fx.writeLog(number: 8, batches: [B(sequence: 5, ops: [(d("b"), d("2"))])])
        try fx.writeManifest(logNumber: 8, prevLogNumber: 7, lastSequence: 5, liveTables: [])
        let r = LevelDBReader(folder: folder)
        XCTAssertEqual(try r.manifest().prevLogNumber, 7)
        XCTAssertEqual(try r.entries { _ in true }.count, 2)
    }

    func testFragmentedLogRecordIsReassembled() throws {
        let big = d("big")
        try fx.writeLog(number: 8, batches: [B(sequence: 1, ops: [(d("small"), d("s"))]),
                                             B(sequence: 2, ops: [(big, Data(repeating: 0x42, count: 40_000))])])
        try fx.writeManifest(logNumber: 8, lastSequence: 2, liveTables: [])
        XCTAssertEqual(try LevelDBReader(folder: folder).newest(big)?.value.count, 40_000)
    }

    func testTornTailToleratedOnlyWhenAsked() throws {
        let torn = LevelDBFixture.logFile([[1, 2, 3, 4], [5, 6, 7, 8, 9, 10]], tearLastRecord: true)
        XCTAssertEqual(try LevelDBReader.logRecords(torn, tolerateTornTail: true), [[1, 2, 3, 4]])
        XCTAssertThrowsError(try LevelDBReader.logRecords(torn, tolerateTornTail: false))
    }

    func testChecksumFailureOnLastRecordToleratedButNotInTheMiddle() throws {
        var bytes = LevelDBFixture.logFile([[1, 2, 3], [4, 5, 6]], tearLastRecord: false)
        var lastCorrupt = bytes; lastCorrupt[lastCorrupt.count - 1] ^= 0xFF
        XCTAssertEqual(try LevelDBReader.logRecords(lastCorrupt, tolerateTornTail: true), [[1, 2, 3]])
        XCTAssertThrowsError(try LevelDBReader.logRecords(lastCorrupt, tolerateTornTail: false))
        bytes[7] ^= 0xFF   // first record's payload
        XCTAssertThrowsError(try LevelDBReader.logRecords(bytes, tolerateTornTail: true))
    }

    func testMaxSequenceIncludesManifestLastSequence() throws {
        try fx.writeLog(number: 8, batches: [B(sequence: 299, ops: [(d("a"), d("1")), (d("b"), d("2"))])])
        try fx.writeManifest(logNumber: 8, lastSequence: 500, liveTables: [])
        XCTAssertEqual(try LevelDBReader(folder: folder).maxSequence(), 500)
    }

    func testMaxSequenceCoversLogsBeyondManifest() throws {
        try fx.writeLog(number: 8, batches: [B(sequence: 600, ops: [(d("a"), d("1")), (d("b"), d("2"))])])
        try fx.writeManifest(logNumber: 8, lastSequence: 500, liveTables: [])
        XCTAssertEqual(try LevelDBReader(folder: folder).maxSequence(), 601)
    }

    func testCurrentLogURLIsPaddedLogNumber() throws {
        try fx.writeManifest(logNumber: 42, lastSequence: 1, liveTables: [])
        XCTAssertEqual(try LevelDBReader(folder: folder).currentLogURL().lastPathComponent, "000042.log")
    }

    func testCorruptTableChecksumIsRejected() throws {
        try fx.writeTable(number: 5, records: [R(d("k"), d("v"), seq: 1)])
        try fx.writeManifest(logNumber: 8, lastSequence: 1, liveTables: [5])
        let url = folder.appendingPathComponent("000005.ldb")
        var bytes = try Data(contentsOf: url); bytes[3] ^= 0xFF; try bytes.write(to: url)
        XCTAssertThrowsError(try LevelDBReader(folder: folder).newest(d("k"))) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "leveldb read failed")
        }
    }

    func testMissingLiveTableIsRejected() throws {
        try fx.writeManifest(logNumber: 8, lastSequence: 1, liveTables: [5])
        XCTAssertThrowsError(try LevelDBReader(folder: folder).maxSequence())
    }

    func testMissingCurrentIsRejected() {
        XCTAssertThrowsError(try LevelDBReader(folder: folder).manifest())
    }
}
