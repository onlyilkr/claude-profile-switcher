import XCTest
@testable import SwitcherCore

final class ClaudeStoreCodecTests: XCTestCase {
    func testCRC32CKnownVector() { XCTAssertEqual(CRC32C.checksum(Array("123456789".utf8)), 0xE3069283) }
    func testMaskMatchesLevelDB() { XCTAssertEqual(CRC32C.masked(0), 0xA282EAD8) }
    func testSnappyLiteral() throws { XCTAssertEqual(try Snappy.decompress([0x05, 0x10] + Array("hello".utf8)), Array("hello".utf8)) }
    func testSnappyCopy() throws {
        // "abcabcabc": literal "abc" then copy-1 (len 6, offset 3)
        XCTAssertEqual(try Snappy.decompress([0x09, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03]), Array("abcabcabc".utf8))
    }
    func testSnappyRejectsLengthMismatch() { XCTAssertThrowsError(try Snappy.decompress([0x09, 0x08, 0x61, 0x62, 0x63])) }
    func testSnappyLongLiteralWithOneExtraLengthByte() throws {
        let data = [UInt8](repeating: 0x7A, count: 100)
        // tag 60 << 2 = 0xF0 means "one length byte follows" (length - 1 = 99)
        XCTAssertEqual(try Snappy.decompress([0x64, 0xF0, 0x63] + data), data)
    }
    func testSnappyCopyWithTwoByteOffset() throws {
        XCTAssertEqual(try Snappy.decompress([0x09, 0x08, 0x61, 0x62, 0x63, 0x16, 0x03, 0x00]), Array("abcabcabc".utf8))
    }
    func testSnappyCopyWithFourByteOffset() throws {
        XCTAssertEqual(try Snappy.decompress([0x09, 0x08, 0x61, 0x62, 0x63, 0x17, 0x03, 0x00, 0x00, 0x00]), Array("abcabcabc".utf8))
    }
    func testSnappyOverlappingCopyRepeatsThePattern() throws {
        // literal "a", then copy of 8 bytes from offset 1
        XCTAssertEqual(try Snappy.decompress([0x09, 0x00, 0x61, 0x1E, 0x01, 0x00]), Array("aaaaaaaaa".utf8))
    }
    func testSnappyRejectsOffsetZero() { XCTAssertThrowsError(try Snappy.decompress([0x05, 0x00, 0x61, 0x01, 0x00])) }
    func testSnappyRejectsOffsetBeyondOutput() { XCTAssertThrowsError(try Snappy.decompress([0x05, 0x00, 0x61, 0x0E, 0x05, 0x00])) }
    func testCRC32CChainingEqualsOneShot() {
        let a = Array("12345".utf8), b = Array("6789".utf8)
        XCTAssertEqual(CRC32C.checksum(b, seed: CRC32C.checksum(a)), CRC32C.checksum(a + b))
    }
}
