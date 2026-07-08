import XCTest
@testable import BuddyCore

// MARK: - SnipScriptFunctionTests
//
// 蓝队单测：snip.sh / snippets.sh 纯函数（shell 行为契约）
//
// 通过 Process 真实执行 shell 脚本，验证：
//   - expand_placeholders（{date}/{time}/{clipboard} 展开；未定义原样保留）
//   - 模糊匹配（snippets_search）
//   - 原子写（snippets_add 后文件合法）
//   - 降级（损坏文件拒写、缺失文件视为空、未定义占位符原样保留）
//
// 契约引用（state.md）：C5 占位符 / C6 原子写 / C11 不崩退出码 / AC-SNIP-19/20
//
// 注：用 Process 跑 bash 脚本，BUDDY_SNIPPETS_FILE 隔离到 tmpDir，不污染用户数据。

final class SnipScriptFunctionTests: XCTestCase {

    private var tmpDir: URL!
    private var snippetsFile: URL!
    private let snippetsShPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()  // Launcher/
        .deletingLastPathComponent()  // BuddyCoreTests/
        .deletingLastPathComponent()  // tests/
        .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/snip/lib/snippets.sh")

    // 社区插件 monorepo 路径（开发期从本地 clone 拉）
    private let monorepoSnippetsSh = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("workspace/buddy-official-plugins/plugins/snip/lib/snippets.sh")

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnipScript-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        snippetsFile = tmpDir.appendingPathComponent("snippets.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// 解析 snippets.sh 路径：优先本地 monorepo（开发期），回退 build-time fetch 产物
    private var effectiveSnippetsSh: URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: monorepoSnippetsSh.path) { return monorepoSnippetsSh }
        return snippetsShPath
    }

    // MARK: - 辅助：跑 snippets.sh 函数

    private func runSnippetsFunction(_ expr: String, snippetsContent: String? = nil) -> (stdout: String, stderr: String, exit: Int32) {
        if let content = snippetsContent {
            try? content.write(to: snippetsFile, atomically: true, encoding: .utf8)
        }
        // source snippets.sh + 执行表达式
        let script = """
        set -euo pipefail
        export BUDDY_SNIPPETS_FILE="\(snippetsFile.path)"
        . "\(effectiveSnippetsSh.path)"
        \(expr)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", "\(error)", -1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    // MARK: - expand_placeholders（C5 / AC-SNIP-19）

    func test_expandPlaceholders_date_replaced() {
        let (out, _, exit) = runSnippetsFunction("expand_placeholders '今天是 {date}'")
        XCTAssertEqual(exit, 0)
        // 匹配 YYYY-MM-DD
        let regex = try! NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}")
        XCTAssertTrue(regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) != nil,
                      "{date} 应展开为 YYYY-MM-DD，实际: \(out)")
    }

    func test_expandPlaceholders_time_replaced() {
        let (out, _, exit) = runSnippetsFunction("expand_placeholders '时间 {time}'")
        XCTAssertEqual(exit, 0)
        let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}")
        XCTAssertTrue(regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) != nil,
                      "{time} 应展开为 HH:MM，实际: \(out)")
    }

    func test_expandPlaceholders_clipboard_replaced() {
        // 先写剪贴板，再展开
        let pbSetup = "echo -n 'CLIP_TEST_VALUE' | pbpaste"
        let script = """
        set -euo pipefail
        export BUDDY_SNIPPETS_FILE="\(snippetsFile.path)"
        echo -n 'CLIP_TEST_VALUE' | pbcopy
        . "\(effectiveSnippetsSh.path)"
        expand_placeholders '前缀 {clipboard} 后缀'
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(out, "前缀 CLIP_TEST_VALUE 后缀", "{clipboard} 应展开为剪贴板内容")
    }

    // AC-SNIP-19：未定义占位符原样保留（降级锁定）
    func test_expandPlaceholders_undefinedPreserved() {
        let (out, _, exit) = runSnippetsFunction("expand_placeholders 'a {nope} b'")
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(out, "a {nope} b", "未定义占位符应原样保留")
    }

    // AC-SNIP-19：畸形占位符（未闭合）原样保留
    func test_expandPlaceholders_malformedPreserved() {
        let (out, _, exit) = runSnippetsFunction("expand_placeholders 'x {date y'")
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(out, "x {date y", "畸形占位符应原样保留")
    }

    // MARK: - snippets_add（C6 原子写 + C9 数据模型）

    func test_snippetsAdd_writesValidJson() {
        let (_, _, exit) = runSnippetsFunction("snippets_add sig '张三' >/dev/null")
        XCTAssertEqual(exit, 0, "add 应成功")
        // 验证文件是合法 JSON 数组
        let content = (try? String(contentsOf: snippetsFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("\"keyword\":\"sig\""), "文件应含 keyword:sig")
        XCTAssertTrue(content.contains("\"content\":\"张三\""), "文件应含 content")
        XCTAssertTrue(content.contains("\"created_at\""), "文件应含 created_at（C9）")
        XCTAssertTrue(content.contains("\"updated_at\""), "文件应含 updated_at（C9）")
        XCTAssertTrue(content.hasPrefix("[") && content.hasSuffix("]"), "顶级应为数组（C9）")
    }

    func test_snippetsAdd_duplicateFails() {
        _ = runSnippetsFunction("snippets_add sig 'a' >/dev/null")
        let (out, _, exit) = runSnippetsFunction("snippets_add sig 'b' 2>&1")
        XCTAssertNotEqual(exit, 0, "重复 add 应失败")
        XCTAssertTrue(out.contains("已存在"), "应提示已存在（stderr 合并到 stdout）: \(out)")
    }

    // MARK: - snippets_search（模糊匹配）

    func test_snippetsSearch_caseInsensitive() {
        _ = runSnippetsFunction("snippets_add Signature '内容' >/dev/null")
        let (out, _, exit) = runSnippetsFunction("snippets_search 'sig'")
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(out.contains("\"keyword\":\"Signature\""), "模糊匹配 sig 应命中 Signature: \(out)")
    }

    // MARK: - 降级（C11 / AC-SNIP-20）

    // AC-SNIP-20：缺失文件视为空数组（不崩）
    func test_snippetsLoad_missingFile_returnsEmptyArray() {
        let (out, _, exit) = runSnippetsFunction("snippets_load")
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "[]",
                       "缺失文件应返回空数组（trim 换行）")
    }

    // AC-SNIP-20：损坏文件 → load 报错返回非 0
    func test_snippetsLoad_corruptedFile_returnsError() {
        let (_, _, exit) = runSnippetsFunction("snippets_load", snippetsContent: "not json {{{")
        XCTAssertEqual(exit, 1, "损坏文件 load 应返回 exit 1（拒操作保护数据）")
    }

    // AC-SNIP-20：损坏文件 → add 拒写保护数据
    func test_snippetsAdd_corruptedFile_refusesWrite() {
        let (out, _, exit) = runSnippetsFunction("snippets_add x 'y' 2>&1", snippetsContent: "corrupted")
        XCTAssertNotEqual(exit, 0, "损坏文件 add 应失败（拒写）")
        XCTAssertTrue(out.contains("损坏"), "应提示损坏（stderr 合并到 stdout）: \(out)")
        // 文件内容应未被覆盖
        let content = (try? String(contentsOf: snippetsFile, encoding: .utf8)) ?? ""
        XCTAssertEqual(content, "corrupted", "损坏的文件不应被覆盖（保护数据）")
    }

    // MARK: - validate_keyword（C8 白名单）

    func test_validateKeyword_validChars() {
        let valid = ["sig", "addr_1", "my-key", "ABC123", "_under", "-dash"]
        for kw in valid {
            let (_, _, exit) = runSnippetsFunction("validate_keyword '\(kw)'")
            XCTAssertEqual(exit, 0, "合法 keyword '\(kw)' 应通过")
        }
    }

    func test_validateKeyword_invalidChars() {
        let invalid = ["bad kw", "with/slash", "inj;cmd", "space ", "中文"]
        for kw in invalid {
            let (_, _, exit) = runSnippetsFunction("validate_keyword '\(kw)'")
            XCTAssertNotEqual(exit, 0, "非法 keyword '\(kw)' 应被拒")
        }
    }
}
