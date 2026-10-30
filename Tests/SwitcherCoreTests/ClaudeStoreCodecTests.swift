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
}
