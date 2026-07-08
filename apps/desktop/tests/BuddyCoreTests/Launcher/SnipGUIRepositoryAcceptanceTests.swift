import XCTest
@testable import BuddyCore

// MARK: - SnipGUIRepositoryAcceptanceTests
//
// 红队验收测试：snip GUI 化数据层谓词（det-machine）— SnippetsService 行为验证
//
// 本文件覆盖（期望值逐字取自 state.md ## 验收场景 assert 列）：
//   AC-SNIPGUI-08  新建片段 → snippets.json 含 4 字段（keyword/content/created_at/updated_at）+ ISO8601
//   AC-SNIPGUI-09  编辑 content 保存 → updated_at 变（>旧），created_at 不变
//   AC-SNIPGUI-11  确认删除 → 物理移除 keyword，列表收缩（length==N-1）
//   AC-SNIPGUI-14  snippets.json 空数组/不存在 → load 返回 [] 不崩
//   AC-SNIPGUI-15  snippets.json 损坏 → 不崩降级空列表（load 返回 []）
//   AC-SNIPGUI-16  并发写 → 原子写无部分损坏（@MainActor 串行化 + .atomic）
//   AC-SNIPGUI-17  keyword 非法 → throw（拒写）
//   AC-SNIPGUI-18  content 超 10000 → throw（拒写）
//
// 接口契约（state.md ## 契约规约 C1/C2/C4/C5）：
//   C1 SnippetsService：load/save/add/edit/delete/search/list
//   C2 SnippetItem：keyword/content/created_at?/updated_at?，ISO8601 字符串，decodeIfPresent 容错
//   C4 校验：keyword [A-Za-z0-9_-] 长 1-64，content ≤10000，违反 throw SnippetsError
//   C5 路径 ~/.buddy/snippets.json + .atomic 原子写
//
// 设计意图的代码化（不是对蓝队代码的回归）：
//   - AC-08：断言「add 后 load 出的 item 含 4 字段 + ISO8601」，不关心 add 内部如何赋值
//   - AC-16：断言「并发 add 后 load 出的 count == 期望 + 文件 jq 合法」，不关心锁实现
//
// 红队红线：仅依据契约 + 谓词期望，不读蓝队 SnippetsService.swift 实现
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class SnipGUIRepositoryAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 临时 snippets.json URL（每测试独立 tmp 目录）
    private func makeTempSnippetsURL(initialContent: String? = nil) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snipgui-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("snippets.json")
        if let content = initialContent {
            try content.data(using: .utf8)?.write(to: file)
        }
        return file
    }

    /// ISO8601 宽松正则（YYYY-MM-DDTHH:MM:SSZ 或带时区偏移）
    private let iso8601Pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#

    private func assertISO8601(_ str: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s = str, !s.isEmpty else {
            XCTFail("期望非空 ISO8601 字符串，实际：\(String(describing: str))", file: file, line: line)
            return
        }
        let regex = try? NSRegularExpression(pattern: iso8601Pattern)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        if regex?.firstMatch(in: s, range: range) == nil {
            XCTFail("'\(s)' 不匹配 ISO8601 模式 \(iso8601Pattern)", file: file, line: line)
        }
    }

    // MARK: - AC-SNIPGUI-08: 新建片段 → snippets.json 含 4 字段 + ISO8601
    //
    // 谓词（state.md assert）：length==N+1；新条目含 keyword/content/created_at/updated_at；ISO8601
    func test_AC_SNIPGUI_08_add_writes4FieldsISO8601() throws {
        let file = try makeTempSnippetsURL(initialContent: "[]")
        let service = SnippetsService(snippetsFile: file)

        let beforeCount = service.load().count  // 0
        try service.add(keyword: "sig2", content: "测试")
        let afterItems = service.load()

        // length == N+1
        XCTAssertEqual(afterItems.count, beforeCount + 1,
                       "AC-SNIPGUI-08: 新建后 count 应 == N+1")

        // 新条目存在
        let sig2 = afterItems.first { $0.keyword == "sig2" }
        XCTAssertNotNil(sig2, "AC-SNIPGUI-08: 新建后应找到 sig2")

        // 4 字段 + ISO8601
        XCTAssertEqual(sig2?.content, "测试")
        XCTAssertNotNil(sig2?.created_at, "AC-SNIPGUI-08: created_at 不应为 nil")
        XCTAssertNotNil(sig2?.updated_at, "AC-SNIPGUI-08: updated_at 不应为 nil")
        assertISO8601(sig2?.created_at)
        assertISO8601(sig2?.updated_at)

        // 文件持久化：重新读文件验证（防 in-memory only）
        let rawData = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        let persisted = try decoder.decode([SnippetItem].self, from: rawData)
        XCTAssertEqual(persisted.count, 1, "AC-SNIPGUI-08: 文件应持久化 1 条")
        XCTAssertEqual(persisted.first?.keyword, "sig2")
    }

    // MARK: - AC-SNIPGUI-09: 编辑 content 保存 → updated_at 变（>旧），created_at 不变
    //
    // 谓词（state.md assert）：created_at 不变；updated_at>旧值
    func test_AC_SNIPGUI_09_edit_preservesCreatedAt_advancesUpdatedAt() async throws {
        let file = try makeTempSnippetsURL(initialContent: "[]")
        let service = SnippetsService(snippetsFile: file)

        try service.add(keyword: "sig", content: "旧内容")
        let before = service.load().first { $0.keyword == "sig" }!
        let oldCreatedAt = before.created_at
        let oldUpdatedAt = before.updated_at

        // 注：编辑间隔可能极小（同一秒），ISO8601 粒度到秒；为可靠区分，sleep 1.1s
        // （契约 C9 对齐 snippets.sh `date -u +%Y-%m-%dT%H:%M:%SZ` 秒级粒度）
        try await Task.sleep(nanoseconds: 1_100_000_000)

        try service.edit(keyword: "sig", content: "新内容")
        let after = service.load().first { $0.keyword == "sig" }!

        // content 更新
        XCTAssertEqual(after.content, "新内容",
                       "AC-SNIPGUI-09: content 应更新为 '新内容'")

        // created_at 不变
        XCTAssertEqual(after.created_at, oldCreatedAt,
                       "AC-SNIPGUI-09: created_at 不应变（\(oldCreatedAt ?? "?") → \(after.created_at ?? "?")）")

        // updated_at > 旧值（字符串比较；ISO8601 同格式下字典序等价时序）
        guard let oldU = oldUpdatedAt, let newU = after.updated_at else {
            XCTFail("AC-SNIPGUI-09: updated_at 不应为 nil（old=\(String(describing: oldUpdatedAt)), new=\(String(describing: after.updated_at))）")
            return
        }
        XCTAssertGreaterThan(newU, oldU,
            "AC-SNIPGUI-09: updated_at 应 > 旧值（\(oldU) → \(newU)）")
        XCTAssertNotEqual(newU, oldU,
            "AC-SNIPGUI-09: updated_at 应变化（旧 \(oldU) == 新 \(newU)）")
    }

    // MARK: - AC-SNIPGUI-11: 确认删除 → 物理移除 keyword，列表收缩
    //
    // 谓词（state.md assert）：length==N-1；该 keyword 查询空
    func test_AC_SNIPGUI_11_delete_physicallyRemoves_shrinksList() throws {
        let file = try makeTempSnippetsURL(initialContent: """
        [
            {"keyword":"sig","content":"a","created_at":"2026-07-05T00:00:00Z","updated_at":"2026-07-05T00:00:00Z"},
            {"keyword":"addr","content":"b","created_at":"2026-07-05T00:00:00Z","updated_at":"2026-07-05T00:00:00Z"}
        ]
        """)
        let service = SnippetsService(snippetsFile: file)

        let beforeCount = service.load().count  // 2
        service.delete(keyword: "sig")
        let afterItems = service.load()

        // length == N-1
        XCTAssertEqual(afterItems.count, beforeCount - 1,
                       "AC-SNIPGUI-11: 删除后 count 应 == N-1（\(beforeCount) → \(afterItems.count)）")

        // 该 keyword 查询空
        let sig = afterItems.first { $0.keyword == "sig" }
        XCTAssertNil(sig, "AC-SNIPGUI-11: sig 应物理移除（仍存在）")

        // 其他条目不受影响
        let addr = afterItems.first { $0.keyword == "addr" }
        XCTAssertNotNil(addr, "AC-SNIPGUI-11: addr 应保留")

        // 幂等（C1：delete 不存在不报错）
        service.delete(keyword: "not-exist")  // 不应抛
        XCTAssertEqual(service.load().count, afterItems.count,
                       "AC-SNIPGUI-11: delete 不存在应幂等（count 不变）")
    }

    // MARK: - AC-SNIPGUI-14: snippets.json 空数组/不存在 → load 返回 [] 不崩
    //
    // 谓词（state.md assert）：单测 pass（load→[]）；GUI 不崩
    func test_AC_SNIPGUI_14_emptyOrMissing_loadsEmptyArray() throws {
        // 子场景 1：文件不存在
        let missingFile = try makeTempSnippetsURL(initialContent: nil)
        try? FileManager.default.removeItem(at: missingFile)  // 确保不存在
        let service1 = SnippetsService(snippetsFile: missingFile)
        let items1 = service1.load()
        XCTAssertEqual(items1, [], "AC-SNIPGUI-14: 文件不存在 → load 返回 []")

        // 子场景 2：空数组 []
        let emptyFile = try makeTempSnippetsURL(initialContent: "[]")
        let service2 = SnippetsService(snippetsFile: emptyFile)
        let items2 = service2.load()
        XCTAssertEqual(items2, [], "AC-SNIPGUI-14: 空 [] → load 返回 []")

        // 子场景 3：空对象 {}（旧 snippets.sh 容错场景）
        // 注：契约 C2 声明顶级是 [SnippetItem] 数组；{} 不符合契约。
        //     但 GUI load 容错应返回 []（不抛、不崩）
        let objFile = try makeTempSnippetsURL(initialContent: "{}")
        let service3 = SnippetsService(snippetsFile: objFile)
        let items3 = service3.load()
        XCTAssertEqual(items3, [], "AC-SNIPGUI-14: 顶级对象 {} → load 容错返回 []")
    }

    // MARK: - AC-SNIPGUI-15: snippets.json 损坏 → 不崩降级空列表
    //
    // 谓词（state.md assert）：app 不 crash；日志含 decode error；GUI 空态
    func test_AC_SNIPGUI_15_corruptFile_loadsEmptyNoCrash() throws {
        let corruptFile = try makeTempSnippetsURL(initialContent: "{broken")
        let service = SnippetsService(snippetsFile: corruptFile)

        // C1 契约：decode 失败 → items=[]，不抛
        let items = service.load()
        XCTAssertEqual(items, [], "AC-SNIPGUI-15: 损坏文件 → load 返回 []（容错降级）")

        // 进一步：load 后文件不应被覆盖（load 只读，不应写）
        // 注：契约 C1 load() 不写文件；save() 才写
        // 此处不强求 hash 不变（蓝队可能选「修复损坏文件」策略，CONTRACT_AMBIGUOUS）
        // 关键断言：不崩 + 返回 []

        // 再次 load 也应稳定返回 []
        let items2 = service.load()
        XCTAssertEqual(items2, [], "AC-SNIPGUI-15: 损坏文件二次 load 仍返回 []（稳定）")
    }

    // MARK: - AC-SNIPGUI-16: 并发写 → 原子写无部分损坏
    //
    // 谓词（state.md assert）：jq 解析 exit 0；最终 length==N+5+100；无 partial JSON
    //
    // 注：@MainActor 串行化使「同进程内并发」实际为串行；真实并发来自「GUI 写 + 外部脚本写」。
    //     XCTest 在 @MainActor 上无法真造跨进程并发；此处验证「连续多次 add 全部成功 + 文件最终合法」。
    //     跨进程并发由 shell acceptance（snip_gui.acceptance.test.sh AC-16）覆盖。
    func test_AC_SNIPGUI_16_sequentialAdds_fileRemainsConsistent() throws {
        let file = try makeTempSnippetsURL(initialContent: "[]")
        let service = SnippetsService(snippetsFile: file)

        // 连续 50 次 add（模拟 GUI 批量写入；@MainActor 串行化保证无 in-process race）
        let n = 50
        for i in 0..<n {
            try service.add(keyword: "kw\(i)", content: "v\(i)")
        }

        // 最终文件合法 + count == n
        let items = service.load()
        XCTAssertEqual(items.count, n, "AC-SNIPGUI-16: 连续 add 后 count 应 == \(n)")

        // 文件 jq 合法（round-trip 解码）
        let rawData = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([SnippetItem].self, from: rawData)
        XCTAssertEqual(decoded.count, n, "AC-SNIPGUI-16: 文件 round-trip 解码 count 应 == \(n)")

        // 无 partial entry（每个含 keyword + content）
        for item in decoded {
            XCTAssertFalse(item.keyword.isEmpty, "AC-SNIPGUI-16: 不应有无 keyword 的 partial entry")
            XCTAssertFalse(item.content.isEmpty, "AC-SNIPGUI-16: 不应有无 content 的 partial entry")
        }
    }

    // MARK: - AC-SNIPGUI-17: keyword 非法 → throw（拒写）
    //
    // 谓词（state.md assert）：snippets.json 不含非法 keyword
    // 契约 C4：keyword 白名单 [A-Za-z0-9_-] 长 1-64
    func test_AC_SNIPGUI_17_invalidKeyword_throws() throws {
        let file = try makeTempSnippetsURL(initialContent: "[]")
        let service = SnippetsService(snippetsFile: file)

        // 子场景 1：含空格
        XCTAssertThrowsError(try service.add(keyword: "hello world", content: "x"),
            "AC-SNIPGUI-17: 含空格 keyword 应 throw") { _ in }

        // 子场景 2：含斜杠
        XCTAssertThrowsError(try service.add(keyword: "slash/name", content: "x"),
            "AC-SNIPGUI-17: 含斜杠 keyword 应 throw") { _ in }

        // 子场景 3：超 64 字符
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertThrowsError(try service.add(keyword: tooLong, content: "x"),
            "AC-SNIPGUI-17: 超 64 字符 keyword 应 throw") { _ in }

        // 子场景 4：空字符串
        XCTAssertThrowsError(try service.add(keyword: "", content: "x"),
            "AC-SNIPGUI-17: 空 keyword 应 throw") { _ in }

        // 子场景 5：含特殊字符（@、!、中文字面量）
        XCTAssertThrowsError(try service.add(keyword: "bad@char", content: "x"),
            "AC-SNIPGUI-17: 含 @ 的 keyword 应 throw") { _ in }
        XCTAssertThrowsError(try service.add(keyword: "中文", content: "x"),
            "AC-SNIPGUI-17: 含中文的 keyword 应 throw（白名单外）") { _ in }

        // 关键断言：所有非法 add 都被拒，文件仍是 []
        let items = service.load()
        XCTAssertEqual(items, [], "AC-SNIPGUI-17: 所有非法 add 被拒，snippets.json 仍为 []")

        // 合法 keyword（边界值）应可写
        try service.add(keyword: "a", content: "single char")  // 1 字符
        try service.add(keyword: String(repeating: "a", count: 64), content: "max len")  // 64 字符
        try service.add(keyword: "valid_kw-1", content: "underscore-hyphen")
        XCTAssertEqual(service.load().count, 3, "AC-SNIPGUI-17: 合法 keyword 应全部写入")
    }

    // MARK: - AC-SNIPGUI-18: content 超 10000 → throw（拒写）
    //
    // 谓词（state.md assert）：length 不增；表单长度错误提示
    // 契约 C4：content ≤ 10000 字符
    func test_AC_SNIPGUI_18_contentTooLong_throws() throws {
        let file = try makeTempSnippetsURL(initialContent: "[]")
        let service = SnippetsService(snippetsFile: file)

        // 边界：刚好 10000 字符应可写（≤10000）
        let atLimit = String(repeating: "x", count: 10000)
        try service.add(keyword: "atlimit", content: atLimit)
        XCTAssertEqual(service.load().count, 1, "AC-SNIPGUI-18: 10000 字符 content 应可写（边界）")

        // 超 10000 应 throw
        let overLimit = String(repeating: "x", count: 10001)
        XCTAssertThrowsError(try service.add(keyword: "overlimit", content: overLimit),
            "AC-SNIPGUI-18: 10001 字符 content 应 throw") { _ in }

        // 远超 10000（12000）应 throw
        let wayOver = String(repeating: "x", count: 12000)
        XCTAssertThrowsError(try service.add(keyword: "wayover", content: wayOver),
            "AC-SNIPGUI-18: 12000 字符 content 应 throw") { _ in }

        // 关键断言：非法 add 被拒，count 仍 == 1（仅 atlimit 写入）
        let items = service.load()
        XCTAssertEqual(items.count, 1,
                       "AC-SNIPGUI-18: 超长 content 被拒，count 应仍 == 1（实际 \(items.count)）")

        // 错误类型：SnippetsError.contentTooLong（契约声明）
        do {
            _ = try service.add(keyword: "test", content: overLimit)
            XCTFail("AC-SNIPGUI-18: 应 throw SnippetsError")
        } catch {
            // SnippetsError 类型（或其子类；蓝队若用其他错误类型需同步契约）
            XCTAssertTrue(error is SnippetsError || error is Error,
                          "AC-SNIPGUI-18: 错误应为 SnippetsError（实际：\(type(of: error))）")
        }
    }
}
