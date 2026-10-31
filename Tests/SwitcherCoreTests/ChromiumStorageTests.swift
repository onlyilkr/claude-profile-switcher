import XCTest
@testable import SwitcherCore

final class ChromiumStorageTests: XCTestCase {
    private var folder: URL!
    private var fx: LevelDBFixture!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        folder = LevelDBFixture.tempFolder()
        fx = try LevelDBFixture(folder: folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private let json = #"{"state":{"starredIds":["local_a","local_b"]},"version":0,"updatedAt":1}"#
    private let storeName = "store:pin-state:dframe-starred-code"

    private func varint(_ v: UInt64) -> [UInt8] { LevelDBFixture.varint(v) }

    private func idbKey(prefix: [UInt8], name: String? = nil) -> Data {
        let n = name ?? storeName
        var k = prefix + [0x01] + varint(UInt64(n.utf16.count))
        for u in n.utf16 { k += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return Data(k)
    }

    private func idbValue(string: UInt8 = 0x22, version: UInt8 = 0x15, json: String? = nil, trailing: [UInt8] = []) -> Data {
        let body = Array((json ?? self.json).utf8)
        return Data([0x04, 0xFF, version, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 0x10, string] + varint(UInt64(body.count)) + body + trailing)
    }

    private func reader(_ ops: [(key: Data, value: Data?)]) throws -> LevelDBReader {
        try fx.writeLog(number: 3, batches: [.init(sequence: 1, ops: ops)])
        try fx.writeManifest(logNumber: 3, lastSequence: UInt64(ops.count), liveTables: [])
        return LevelDBReader(folder: folder)
    }

    func testLocalStorageLatin1RoundTrip() throws {
        XCTAssertEqual(try LocalStorageCodec.decode(LocalStorageCodec.encode("abc")), "abc")
        XCTAssertEqual(LocalStorageCodec.encode("abc").first, 0x01)
    }

    func testLocalStorageUsesUTF16AboveLatin1() throws {
        let e = LocalStorageCodec.encode("klasör ş")
        XCTAssertEqual(e.first, 0x00)
        XCTAssertEqual(try LocalStorageCodec.decode(e), "klasör ş")
        XCTAssertEqual(LocalStorageCodec.encode("klasör").first, 0x01)
    }

    func testLocalStorageDecodeRejectsUnknownOrOddValues() {
        XCTAssertThrowsError(try LocalStorageCodec.decode(Data()))
        XCTAssertThrowsError(try LocalStorageCodec.decode(Data([0x02, 0x41])))
        XCTAssertThrowsError(try LocalStorageCodec.decode(Data([0x00, 0x41])))
    }

    func testLocalStorageKeyLayout() {
        XCTAssertEqual(LocalStorageCodec.key("dframe-store"), Data("_https://claude.ai".utf8) + Data([0x00, 0x01]) + Data("dframe-store".utf8))
        XCTAssertEqual(LocalStorageCodec.metaKey, Data("META:https://claude.ai".utf8))
    }

    func testMetaUpdate() throws {
        let old = Data([0x08] + varint(123) + [0x10] + varint(1000))
        let m = try LocalStorageCodec.updatedMeta(old, sizeDelta: 45, now: now)
        let micros = UInt64(1_700_000_000 + 11_644_473_600) * 1_000_000
        XCTAssertEqual(m, Data([0x08] + varint(micros) + [0x10] + varint(1045)))
    }

    func testMetaSizeNeverBelowZeroAndUnknownFieldsRefused() throws {
        let old = Data([0x08] + varint(1) + [0x10] + varint(10))
        let m = try LocalStorageCodec.updatedMeta(old, sizeDelta: -50, now: now)
        XCTAssertEqual(m.suffix(2), Data([0x10, 0x00]))
        XCTAssertThrowsError(try LocalStorageCodec.updatedMeta(old + Data([0x18, 0x01]), sizeDelta: 0, now: now))
        XCTAssertThrowsError(try LocalStorageCodec.updatedMeta(Data([0x08, 0x80]), sizeDelta: 0, now: now))
        XCTAssertThrowsError(try LocalStorageCodec.updatedMeta(old, sizeDelta: Int.max, now: now))
    }

    func testFindsPinRecordWithAnyDatabaseID() throws {
        for dbId in [UInt8(1), 5] {
            let f = LevelDBFixture.tempFolder(); defer { try? FileManager.default.removeItem(at: f) }
            fx = try LevelDBFixture(folder: f); folder = f
            let r = try reader([(idbKey(prefix: [0x00, dbId, 0x01, 0x01]), idbValue())])
            XCTAssertEqual(try IndexedDBPins.find(in: r)?.starredIds, ["local_a", "local_b"])
        }
    }

    func testFindsPrefixWithWiderIds() throws {
        // two-byte database id: (2-1)<<5 | (1-1)<<2 | (1-1) = 0x20
        let r = try reader([(idbKey(prefix: [0x20, 0x05, 0x01, 0x01, 0x01]), idbValue())])
        XCTAssertEqual(try IndexedDBPins.find(in: r)?.starredIds.count, 2)
    }

    func testIgnoresExistsEntryIndex() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue()),
                            (idbKey(prefix: [0x00, 0x01, 0x01, 0x02]), Data([0x04]))])
        XCTAssertEqual(try IndexedDBPins.find(in: r)?.starredIds.count, 2)
    }

    func testIgnoresDeletedAndOtherStores() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), nil),
                            (idbKey(prefix: [0x00, 0x01, 0x01, 0x01], name: "store:other"), idbValue())])
        XCTAssertNil(try IndexedDBPins.find(in: r))
    }

    func testTwoLiveRecordsRefused() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue()),
                            (idbKey(prefix: [0x00, 0x05, 0x01, 0x01]), idbValue())])
        XCTAssertThrowsError(try IndexedDBPins.find(in: r)) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "pin store format not recognised")
        }
    }

    func testRefusesTwoByteStringValue() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue(string: 0x63))])
        XCTAssertThrowsError(try IndexedDBPins.find(in: r)) {
            XCTAssertEqual(($0 as? SwitcherError)?.logReason, "pin store format not recognised")
        }
    }

    func testRefusesOtherBlinkVersionAndTrailingBytesAndBadJSON() throws {
        for v in [idbValue(version: 0x14), idbValue(trailing: [0x00]), idbValue(json: #"{"state":{"starredIds":[1]},"version":0,"updatedAt":1}"#),
                  idbValue(json: #"{"state":{"starredIds":[]},"updatedAt":1}"#), idbValue(json: "nope")] {
            let f = LevelDBFixture.tempFolder(); defer { try? FileManager.default.removeItem(at: f) }
            fx = try LevelDBFixture(folder: f); folder = f
            let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), v)])
            XCTAssertThrowsError(try IndexedDBPins.find(in: r))
        }
    }

    func testEncodedKeepsEnvelopeAndVersion() throws {
        let extra = #"{"state":{"starredIds":["local_a"],"other":true},"version":3,"updatedAt":1,"x":"y/z"}"#
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue(json: extra))])
        var rec = try XCTUnwrap(IndexedDBPins.find(in: r))
        rec.starredIds = ["local_c"]
        let v = try rec.encoded(updatedAt: now)
        XCTAssertTrue(v.starts(with: rec.envelope))
        XCTAssertEqual(rec.envelope.last, 0x22)
        let len = Int(v[rec.envelope.count])   // short JSON: one-byte varint
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: v.dropFirst(rec.envelope.count + 1)) as? [String: Any])
        XCTAssertEqual(len, v.count - rec.envelope.count - 1)
        XCTAssertEqual(obj["version"] as? Int, 3)
        XCTAssertEqual(obj["updatedAt"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(obj["x"] as? String, "y/z")
        let st = try XCTUnwrap(obj["state"] as? [String: Any])
        XCTAssertEqual(st["starredIds"] as? [String], ["local_c"])
        XCTAssertEqual(st["other"] as? Bool, true)
    }

    func testEncodedNonLatin1IdsStayValidLatin1Json() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue())])
        var rec = try XCTUnwrap(IndexedDBPins.find(in: r))
        let ids = ["local_é\u{FF}\u{80}", "local_ş\u{20AC}", "local_\u{1F600}"]
        rec.starredIds = ids
        let v = try rec.encoded(updatedAt: now)
        // Every byte is a Latin-1 character, and the text decodes as JSON with the ids intact.
        let text = try XCTUnwrap(String(data: v.dropFirst(rec.envelope.count + 1), encoding: .isoLatin1))
        XCTAssertEqual(Data(text.unicodeScalars.map { UInt8($0.value) }), v.dropFirst(rec.envelope.count + 1))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((obj["state"] as? [String: Any])?["starredIds"] as? [String], ids)
    }

    func testEncodedRefusesUntrappableDates() throws {
        let r = try reader([(idbKey(prefix: [0x00, 0x01, 0x01, 0x01]), idbValue())])
        let rec = try XCTUnwrap(IndexedDBPins.find(in: r))
        for d in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: 1e300), Date(timeIntervalSince1970: -5)] {
            XCTAssertThrowsError(try rec.encoded(updatedAt: d))
        }
    }

    func testNoRecordIsNil() throws {
        try fx.writeLog(number: 3, batches: [.init(sequence: 1, ops: [(Data("k".utf8), Data("v".utf8))])])
        try fx.writeManifest(logNumber: 3, lastSequence: 1, liveTables: [])
        XCTAssertNil(try IndexedDBPins.find(in: LevelDBReader(folder: folder)))
    }
}
