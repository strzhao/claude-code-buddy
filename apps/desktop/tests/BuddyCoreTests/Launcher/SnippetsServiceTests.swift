import XCTest
@testable import BuddyCore

// MARK: - SnippetsServiceTests
//
// 蓝队单测：SnippetsService 数据层（T0，参考 ClipboardHistoryServiceTests 范式）。
//
// 契约引用（state.md ## 契约规约）：
//   C1 接口：load/save/add/edit/delete/search/list
//   C2 schema：ISO8601 字符串时间戳 + 顶级数组（非 wrapper）+ decodeIfPresent 兼容
//   C4 校验：keyword `[A-Za-z0-9_-]` 长 1-64，content ≤10000
//   C5 文件路径 + 原子写 + 容错
//   C6 数据一致性（Swift GUI ↔ shell 取用，由 SnipScriptFunctionTests 联动覆盖）
//
// 覆盖验收场景：AC-SNIPGUI-08/09/11/14/15/16/17/18/24（数据层切片）

@MainActor
final class SnippetsServiceTests: XCTestCase {

    private var tmpDir: URL!
    private var snippetsFile: URL!
    private var service: SnippetsService!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnippetsService-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        snippetsFile = tmpDir.appendingPathComponent("snippets.json")
        service = SnippetsService(snippetsFile: snippetsFile)
    }

    override func tearDown() async throws {
        service = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - C5 load 容错（AC-SNIPGUI-14/15）

    func test_load_missingFile_returnsEmpty() {
        let result = service.load()
        XCTAssertEqual(result, [], "缺失文件应返回空数组（不崩）")
        XCTAssertEqual(service.list(), [])
    }

    func test_load_emptyFile_returnsEmpty() throws {
        try Data().write(to: snippetsFile)
        let result = service.load()
        XCTAssertEqual(result, [], "空文件应返回空数组（不崩）")
    }

    func test_load_corruptedFile_returnsEmptyAndLogs() throws {
        try "{broken".write(to: snippetsFile, atomically: true, encoding: .utf8)
        let result = service.load()
        XCTAssertEqual(result, [], "损坏 JSON 应降级为空列表（不崩）")
        XCTAssertEqual(service.list(), [])
    }

    // MARK: - C2 schema（ISO8601 字符串 + 顶级数组 + decodeIfPresent）

    func test_load_topLevelArray_decodes() throws {
        // 顶级数组（非 {items:[]} 包装），对齐 snippets.sh
        let json = """
        [
            {"keyword":"sig","content":"张三","created_at":"2026-07-05T10:00:00Z","updated_at":"2026-07-05T10:00:00Z"}
        ]
        """
        try json.write(to: snippetsFile, atomically: true, encoding: .utf8)
        service.load()
        XCTAssertEqual(service.list().count, 1)
        XCTAssertEqual(service.list().first?.keyword, "sig")
        XCTAssertEqual(service.list().first?.content, "张三")
        XCTAssertEqual(service.list().first?.created_at, "2026-07-05T10:00:00Z")
    }

    func test_load_legacy_missingTimestamps_decodesIfPresent() throws {
        // AC-SNIPGUI-24：旧版无 created_at/updated_at → decode 不抛（decodeIfPresent）
        let json = """
        [{"keyword":"sig","content":"内容"}]
        """
        try json.write(to: snippetsFile, atomically: true, encoding: .utf8)
        service.load()
        let item = try XCTUnwrap(service.list().first)
        XCTAssertEqual(item.keyword, "sig")
        XCTAssertNil(item.created_at, "旧版无 created_at 应为 nil（向后兼容）")
        XCTAssertNil(item.updated_at)
    }

    // MARK: - C1 CRUD

    func test_add_persistsAndFillsTimestamps() throws {
        try service.add(keyword: "sig", content: "张三")

        // 内存
        XCTAssertEqual(service.list().count, 1)
        let item = try XCTUnwrap(service.list().first)
        XCTAssertEqual(item.keyword, "sig")
        XCTAssertEqual(item.content, "张三")
        XCTAssertNotNil(item.created_at, "add 后 created_at 应填充")
        XCTAssertNotNil(item.updated_at, "add 后 updated_at 应填充")
        XCTAssertEqual(item.created_at, item.updated_at, "add 时 created_at == updated_at")

        // 落盘（C5 原子写）
        let data = try Data(contentsOf: snippetsFile)
        let decoded = try JSONDecoder().decode([SnippetItem].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.keyword, "sig")

        // 文件顶级应是数组（C2）
        let raw = try String(contentsOf: snippetsFile, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix("["), "顶级应是数组（C2）: \(raw)")
        XCTAssertTrue(raw.hasSuffix("]"))
    }

    func test_add_duplicateKeyword_throws() throws {
        try service.add(keyword: "sig", content: "a")
        XCTAssertThrowsError(try service.add(keyword: "sig", content: "b")) { error in
            XCTAssertEqual(error as? SnippetsError, .keywordAlreadyExists)
        }
    }

    func test_edit_keepsCreatedUpdatesUpdated() async throws {
        try service.add(keyword: "sig", content: "old")
        let originalUpdated = service.list().first?.updated_at

        // 短暂 sleep 保证时间戳可区分（ISO8601 秒级精度）
        try await Task.sleep(nanoseconds: 1_100_000_000)

        try service.edit(keyword: "sig", content: "new")
        let edited = try XCTUnwrap(service.list().first)
        XCTAssertEqual(edited.content, "new")
        // created_at 不变（AC-SNIPGUI-09）
        XCTAssertEqual(edited.created_at, service.list().first?.created_at)
        // updated_at 应变（> 旧值）
        XCTAssertNotNil(edited.updated_at)
        XCTAssertNotEqual(edited.updated_at, originalUpdated, "edit 后 updated_at 应更新")
    }

    func test_edit_nonExistent_throws() {
        XCTAssertThrowsError(try service.edit(keyword: "nope", content: "x")) { error in
            XCTAssertEqual(error as? SnippetsError, .keywordNotFound)
        }
    }

    func test_delete_removesItem() throws {
        try service.add(keyword: "a", content: "1")
        try service.add(keyword: "b", content: "2")
        XCTAssertEqual(service.list().count, 2)

        service.delete(keyword: "a")
        XCTAssertEqual(service.list().count, 1)
        XCTAssertFalse(service.list().contains { $0.keyword == "a" })
    }

    func test_delete_nonExistent_idempotent() {
        // 幂等（C1）：不存在不报错
        service.delete(keyword: "nope")
        XCTAssertEqual(service.list().count, 0)
    }

    // MARK: - C1 查询

    func test_list_sortedByKeyword() throws {
        try service.add(keyword: "zeta", content: "z")
        try service.add(keyword: "alpha", content: "a")
        try service.add(keyword: "mid", content: "m")

        let names = service.list().map(\.keyword)
        XCTAssertEqual(names, ["alpha", "mid", "zeta"], "list 应按 keyword 字典序")
    }

    func test_search_caseInsensitive_contains() throws {
        try service.add(keyword: "Signature", content: "x")
        try service.add(keyword: "address", content: "y")
        try service.add(keyword: "phone", content: "z")

        let hits = service.search("sig")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.keyword, "Signature")

        let empty = service.search("")
        XCTAssertEqual(empty.count, 3, "空 query 应返回全部")
    }

    // MARK: - C4 校验（AC-SNIPGUI-17/18）

    func test_add_invalidKeyword_rejected() {
        let invalid = ["hello world", "with/slash", "inj;cmd", "中文", "has space", "dot.dot"]
        for kw in invalid {
            XCTAssertThrowsError(try service.add(keyword: kw, content: "x")) { error in
                XCTAssertEqual(error as? SnippetsError, .invalidKeyword, "非法 keyword '\(kw)' 应被拒")
            }
        }
        // snippets.json 不应含非法 keyword
        XCTAssertEqual(service.list().count, 0)
    }

    func test_add_keywordTooLong_rejected() {
        let long = String(repeating: "a", count: 65)
        XCTAssertThrowsError(try service.add(keyword: long, content: "x")) { error in
            XCTAssertEqual(error as? SnippetsError, .invalidKeyword)
        }
    }

    func test_add_keywordMaxBoundary_accepted() throws {
        // 边界值：刚好 64 字符应通过
        let kw = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try service.add(keyword: kw, content: "x"))
    }

    func test_add_keywordValidChars_accepted() throws {
        let valid = ["sig", "addr_1", "my-key", "ABC123", "_under", "-dash", "MiXeD-Case_9"]
        for kw in valid {
            XCTAssertNoThrow(try service.add(keyword: kw, content: "x"), "合法 keyword '\(kw)' 应通过")
        }
    }

    func test_add_contentTooLong_rejected() {
        let longContent = String(repeating: "x", count: 10_001)
        XCTAssertThrowsError(try service.add(keyword: "ok", content: longContent)) { error in
            XCTAssertEqual(error as? SnippetsError, .contentTooLong)
        }
    }

    func test_add_contentMaxBoundary_accepted() throws {
        // 边界值：刚好 10000 字符应通过
        let content = String(repeating: "x", count: 10_000)
        XCTAssertNoThrow(try service.add(keyword: "ok", content: content))
    }

    // MARK: - C2 时间戳 ISO8601 格式（对齐 snippets.sh `date -u +%Y-%m-%dT%H:%M:%SZ`）

    func test_nowISO8601_matchesShellFormat() {
        let ts = SnippetsService.nowISO8601()
        // 严格匹配 YYYY-MM-DDTHH:MM:SSZ
        let regex = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
        XCTAssertTrue(regex.firstMatch(in: ts, range: NSRange(ts.startIndex..., in: ts)) != nil,
                      "ISO8601 应匹配 YYYY-MM-DDTHH:MM:SSZ, 实际: \(ts)")
    }

    // MARK: - C6 数据一致性（Swift 写 → jq 可解析，跨系统对齐）

    func test_save_outputIsJqParsable() throws {
        try service.add(keyword: "sig", content: "张三 13800138000")

        // 验证写的文件 jq 能解析（C6 跨系统一致性）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["jq", "-r", ".[0].keyword", snippetsFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "jq 应能解析（C6）")
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(out, "sig", "jq 应读到 keyword=sig（C6 Swift↔shell 一致）")
    }
}
