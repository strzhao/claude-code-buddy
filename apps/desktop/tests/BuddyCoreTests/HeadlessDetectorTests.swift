import XCTest
@testable import BuddyCore

/// HeadlessDetector 单测（C-HEADLESS-DETECT）：
/// resolver 注册表反查 / 重试 / fail-open，checker argv 解析纯函数 + ESRCH 分支。
final class HeadlessDetectorTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "buddy-headless-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Registry Helpers

    private func writeRegistry(pid: Int, sessionId: String, procStart: String? = nil) {
        var json: [String: Any] = [
            "pid": pid,
            "sessionId": sessionId,
            "cwd": "/tmp/x",
            "kind": "interactive",   // 实证不可靠字段， resolver 禁止读它判型
        ]
        if let procStart { json["procStart"] = procStart }
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: URL(fileURLWithPath: tempDir + "/\(pid).json"))
    }

    // MARK: - Resolver: scanOnce

    func testScanOnceFindsMatchingSessionId() {
        writeRegistry(pid: 100, sessionId: "abc-1")
        writeRegistry(pid: 200, sessionId: "abc-2")

        let entry = SessionRegistryPidResolver.scanOnce(sessionId: "abc-2", directory: tempDir)
        XCTAssertEqual(entry?.pid, 200)
    }

    func testScanOnceReturnsNilWhenNoMatch() {
        writeRegistry(pid: 100, sessionId: "abc-1")
        XCTAssertNil(SessionRegistryPidResolver.scanOnce(sessionId: "other", directory: tempDir))
    }

    func testScanOnceReturnsNilWhenDirectoryMissing() {
        XCTAssertNil(SessionRegistryPidResolver.scanOnce(sessionId: "abc", directory: "/nonexistent-dir-xyz"))
    }

    func testScanOnceExtractsProcStart() {
        writeRegistry(pid: 300, sessionId: "abc-3", procStart: "Thu Sep 17 13:22:30 2026")
        let entry = SessionRegistryPidResolver.scanOnce(sessionId: "abc-3", directory: tempDir)
        XCTAssertEqual(entry?.procStart, "Thu Sep 17 13:22:30 2026")
    }

    func testScanOnceIgnoresMalformedAndKeyFiles() {
        // 注册表目录里混有 .key 文件与坏 JSON——都应跳过不崩
        try! Data("not-json".utf8).write(to: URL(fileURLWithPath: tempDir + "/999.json"))
        try! Data([0x00, 0x01]).write(to: URL(fileURLWithPath: tempDir + "/998.key"))
        XCTAssertNil(SessionRegistryPidResolver.scanOnce(sessionId: "abc", directory: tempDir))
    }

    // MARK: - Resolver: retry semantics

    func testResolveEntryRetriesUntilFileAppears() async {
        // 快速参数：0.02s × 5 次重试窗口；文件在两次轮询后才出现 → 重试兜住写时机窗口
        let resolver = SessionRegistryPidResolver(sessionsDirectory: tempDir, retryInterval: 0.02, maxRetries: 6)
        let taskId = "late-session"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { [tempDir] in
            var json: [String: Any] = ["pid": 42, "sessionId": taskId]
            let data = try! JSONSerialization.data(withJSONObject: json)
            try! data.write(to: URL(fileURLWithPath: tempDir! + "/42.json"))
        }
        let entry = await resolver.resolveEntry(pidFor: taskId)
        XCTAssertEqual(entry?.pid, 42, "文件延迟落盘应由重试兜住（C-HEADLESS-DETECT 0.5s×4 窗口语义）")
    }

    func testResolveEntryReturnsNilAfterRetriesExhausted() async {
        let resolver = SessionRegistryPidResolver(sessionsDirectory: tempDir, retryInterval: 0.01, maxRetries: 2)
        let entry = await resolver.resolveEntry(pidFor: "never-appears")
        XCTAssertNil(entry, "重试耗尽 → nil（调用方 fail-open）")
    }

    func testRetryConstantsMatchContract() {
        XCTAssertEqual(SessionRegistryPidResolver.resolveRetryInterval, 0.5)
        XCTAssertEqual(SessionRegistryPidResolver.resolveMaxRetries, 4)
    }

    // MARK: - Checker: argv pure function

    func testArgvContainsPrintTokenHeadlessVariants() {
        XCTAssertTrue(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude -p hello --headless"))
        XCTAssertTrue(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude --print hello"))
        XCTAssertTrue(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude  -p"))   // 多空白
        XCTAssertTrue(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude\t-p\tx"))
    }

    func testArgvContainsPrintTokenInteractiveVariants() {
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude --settings {...}"))
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude --resume abc -w branch"))
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken(""))
    }

    func testArgvExactTokenNotSubstring() {
        // 子串形似但非精确 token → 不得误判（C-HEADLESS-DETECT 精确 token 要求）
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude --printer foo"))
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude -pp foo"))
        XCTAssertFalse(ProcessArgsHeadlessChecker.argvContainsPrintToken("claude /usr/bin/print foo"))
    }

    // MARK: - Checker: real process branches

    func testCheckCurrentProcessIsInteractive() {
        // 当前测试进程 argv 无 -p/--print → interactive
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let checker = ProcessArgsHeadlessChecker()
        XCTAssertEqual(checker.check(pid: pid), .interactive)
        XCTAssertFalse(checker.isHeadless(pid: pid))
    }

    func testCheckDeadPidIsProcessDead() {
        // kill(ESRCH) → .processDead（判 dead，不上猫按 C-HEADLESS-CLEANUP 清理）
        let checker = ProcessArgsHeadlessChecker()
        XCTAssertEqual(checker.check(pid: 999_999), .processDead)
    }

    func testProcessStartTimeMatchesRegistryFormat() {
        // lstart 输出与注册表 procStart 同格式（含 4 位年份，非空）
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let start = ProcessArgsHeadlessChecker().processStartTime(pid: pid)
        XCTAssertNotNil(start)
        XCTAssertEqual(start?.count, 24, "期望 'Thu Sep 17 13:22:30 2026' 格式（24 字符）")
    }

    // MARK: - Seam default impls

    func testIsHeadlessDefaultImplDelegatesToCheck() {
        let mock = MockHeadlessChecker(verdict: .headless)
        XCTAssertTrue(mock.isHeadless(pid: 1))
        mock.verdict = .processDead
        XCTAssertFalse(mock.isHeadless(pid: 1), "dead ≠ headless（fail 语义分离）")
    }

    func testResolveDefaultImplDelegatesToResolveEntry() async {
        let mock = MockHeadlessResolver(entry: HeadlessRegistryEntry(pid: 77, procStart: nil))
        let pid = await mock.resolve(pidFor: "s1")
        XCTAssertEqual(pid, 77)
    }
}
