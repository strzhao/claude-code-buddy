import XCTest
@testable import BuddyCore

final class TranscriptReaderTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - transcriptPath

    func testTranscriptPathEncodesSlashes() {
        let result = TranscriptReader.transcriptPath(cwd: "/Users/alice/my-project", sessionId: "abc-123")
        XCTAssertTrue(result.hasSuffix("/abc-123.jsonl"))
        XCTAssertTrue(result.contains("-Users-alice-my-project"))
        XCTAssertFalse(result.contains("/Users/alice"))
    }

    func testTranscriptPathSpecialChars() {
        let result = TranscriptReader.transcriptPath(cwd: "/Users/alice/project name (v2)", sessionId: "s1")
        // Spaces, parens all become dashes
        XCTAssertTrue(result.contains("-Users-alice-project-name--v2-"))
    }

    func testTranscriptPathPreservesAlphanumeric() {
        let result = TranscriptReader.transcriptPath(cwd: "/abc123", sessionId: "s1")
        XCTAssertTrue(result.contains("-abc123"))
    }

    // MARK: - scan

    func testScanMissingFileReturnsZero() {
        let stats = TranscriptReader.scan(path: "/nonexistent/path/file.jsonl")
        XCTAssertNil(stats.model)
        XCTAssertEqual(stats.totalTokens, 0)
    }

    func testScanEmptyFileReturnsZero() {
        let path = tmpDir.appendingPathComponent("empty.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data())
        let stats = TranscriptReader.scan(path: path)
        XCTAssertNil(stats.model)
        XCTAssertEqual(stats.totalTokens, 0)
    }

    func testScanExtractsModelAndTokens() {
        let line = """
        {"type":"assistant","message":{"model":"claude-3-opus","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
        """
        let path = tmpDir.appendingPathComponent("transcript.jsonl").path
        try! line.write(toFile: path, atomically: true, encoding: .utf8)

        let stats = TranscriptReader.scan(path: path)
        XCTAssertEqual(stats.model, "claude-3-opus")
        XCTAssertEqual(stats.totalTokens, 180) // 100+50+20+10
    }

    func testScanAccumulatesAcrossLines() {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-3-opus","usage":{"input_tokens":100,"output_tokens":50}}}"#,
            #"{"type":"assistant","message":{"model":"claude-3-opus","usage":{"input_tokens":200,"output_tokens":30}}}"#,
        ].joined(separator: "\n")
        let path = tmpDir.appendingPathComponent("multi.jsonl").path
        try! lines.write(toFile: path, atomically: true, encoding: .utf8)

        let stats = TranscriptReader.scan(path: path)
        XCTAssertEqual(stats.totalTokens, 380) // (100+50) + (200+30)
    }

    func testScanIgnoresNonAssistantLines() {
        let lines = [
            #"{"type":"user","message":{"content":"hello"}}"#,
            #"{"type":"assistant","message":{"model":"opus","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ].joined(separator: "\n")
        let path = tmpDir.appendingPathComponent("mixed.jsonl").path
        try! lines.write(toFile: path, atomically: true, encoding: .utf8)

        let stats = TranscriptReader.scan(path: path)
        XCTAssertEqual(stats.totalTokens, 15)
    }

    func testScanPicksLastModel() {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-3-haiku","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            #"{"type":"assistant","message":{"model":"claude-3-opus","usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ].joined(separator: "\n")
        let path = tmpDir.appendingPathComponent("models.jsonl").path
        try! lines.write(toFile: path, atomically: true, encoding: .utf8)

        let stats = TranscriptReader.scan(path: path)
        XCTAssertEqual(stats.model, "claude-3-opus")
    }

    // MARK: - readStartedAt

    func testReadStartedAtMissingFileReturnsNil() {
        XCTAssertNil(TranscriptReader.readStartedAt(pid: Int.max))
    }
}
