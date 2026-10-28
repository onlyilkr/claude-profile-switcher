import XCTest
@testable import SwitcherCore

final class SharedChatsTests: XCTestCase {
    func testProjectDirNameMatchesClaude() {
        XCTAssertEqual(
            TranscriptLocator.projectDirName(for: "/Users/ilkerguldali/workspace/halal-backend/.claude/worktrees/sharp-liskov-9f53ee"),
            "-Users-ilkerguldali-workspace-halal-backend--claude-worktrees-sharp-liskov-9f53ee")
        // Every non-alphanumeric UTF-16 unit becomes "-" (after NFC), so letters like Ğ, ü, ş and the space are replaced.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/Users/a/Proje Ğüş"), "-Users-a-Proje----")
        // A character outside the BMP is two UTF-16 units, so it gives two dashes.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/a/😀"), "-a---")
        // Decomposed input is normalised first: "e" + combining acute is one unit after NFC.
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/a/e\u{301}"), "-a--")
    }

    func testLongNamesGetHashSuffix() {
        // Constant computed once outside Swift (32-bit wrapping hash over the UTF-16 units of the raw, unencoded path, base 36).
        let expected = String(repeating: "-", count: 1) + String(repeating: "x", count: 199) + "-v734pd"
        XCTAssertEqual(TranscriptLocator.projectDirName(for: "/" + String(repeating: "x", count: 250)), expected)
        // Exactly 200 characters stays untouched.
        let exact = "/" + String(repeating: "x", count: 199)
        XCTAssertEqual(TranscriptLocator.projectDirName(for: exact), "-" + String(repeating: "x", count: 199))
    }

    func testTranscriptAndSidecarPaths() {
        let root = URL(fileURLWithPath: "/tmp/claude-projects")
        let t = TranscriptLocator.transcript(root: root, cwd: "/a/b", cliSessionID: "sid-1")
        XCTAssertEqual(t.path, "/tmp/claude-projects/-a-b/sid-1.jsonl")
        let s = TranscriptLocator.sidecar(root: root, cwd: "/a/b", cliSessionID: "sid-1")
        XCTAssertEqual(s.path, "/tmp/claude-projects/-a-b/sid-1")
    }
}
