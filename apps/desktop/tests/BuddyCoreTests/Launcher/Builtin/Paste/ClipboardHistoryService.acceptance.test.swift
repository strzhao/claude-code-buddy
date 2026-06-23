import AppKit
import XCTest
@testable import BuddyCore

// MARK: - ClipboardHistoryServiceAcceptanceTests
//
// 红队验收测试：ClipboardHistoryService（常驻监听 + 存储 + 去重 + 排除 + 持久化）
//
// 本文件覆盖（预注册谓词 → 硬断言）：
//   场景3 [det-machine]   四类型各自正确读取（文本/图片/文件路径/富文本）
//   场景5.P1 [det-machine] ConcealedType（密码）排除
//   场景5.P2 [det-machine] TransientType（临时）排除
//   场景5.P3 [det-machine] 持久化文件不含敏感/临时
//   场景6.P1 [det-machine] 连续复制相同内容 → 条目出现次数 == 1
//   场景6.P2 [det-machine] 连续复制相同内容 → 总条目数差 == 0
//   非连续提队首：相同内容隔开后复制 → 提至队首而非新增（hash 命中）
//   边界值谓词：textItems.count <= 500 / imageItems.count <= 50 / 30 天过期
//   JSON 往返：save → load 语义保持（schemaVersion==1）
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Paste/ 下任何实现文件
//   - 仅依据设计文档契约逐字断言（接口签名 + 边界值字面量）
//   - 状态变化测试（去重/回填/排除）必须断言具体值（如 "出现次数 == 1"），反 "有条目" 宽容断言
//   - 注入 NSPasteboard(name:) 隔离 + 临时存储目录，绝不污染系统剪贴板
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。
//
// ISOLATION: 蓝队实现信息隔离，源码扫描留 QA 核对（不读 ClipboardHistoryService.swift）

// CONTRACT_AMBIGUOUS:
//   1. 测试 seam 构造器签名：契约写 `init(pasteboard:storageDir:)`。
//      storageDir 类型契约未明示（URL 还是 String），本测试用 `URL`（Swift 惯例 + FileManager.temporaryDirectory）。
//      若蓝队用 String，编译失败 → 蓝队调整或契约澄清。
//   2. snapshot(filter:) 返回类型：契约写 `[ClipboardHistoryItem]`。
//      空历史 + nil filter 应返回 []（非崩溃），契约隐含。
//   3. 30 天过期判定时机：契约写"启动清理 + 写入后增量裁剪"。
//      本测试用构造器注入预置过期条目（手写 ts < now - 30d）后调 snapshot 验证被过滤，
//      不依赖 Timer 触发（flaky）。
//   4. readPasteboard / append / save / load 是否公开：契约只声明 startMonitoring + snapshot 公开。
//      测试需直接驱动单次读取（不走 Timer），故假定存在可注入触发的 seam——
//      若蓝队将 readPasteboard()/append(_:) 设为 internal，@testable import 可访问；若 private 则需蓝队暴露。
//      本测试按 internal 假设编写（@testable 可达），蓝队若全 private 需提供 scanOnce() 等触发 seam。
//   5. ClipboardHistoryItem.ItemType 枚举命名：契约写 .text/.image/.file/.html。
//      假定 enum ItemType: String, Codable { case text, image, file, html }。
//   6. 图片落盘路径：<sha8>.png 的 sha8 取自 item.hash 前 8 字符（契约 hash 已是 sha256 前 8），
//      故 imagePath 后缀应为 "<hash>.png"。本测试断言 imagePath.contains(item.hash)。
//   7. sourceApp 注入：契约写 NSWorkspace.frontmostApplication.bundleIdentifier。
//      测试无法稳定注入 frontmost app（系统态），故 sourceApp 字段断言为 nil 或非空均可——
//      不做强断言（避免 flaky），仅断言核心字段（content/type/hash/ts）。

@MainActor
final class ClipboardHistoryServiceAcceptanceTests: XCTestCase {

    // MARK: - Helpers（隔离 pasteboard + 临时存储目录）

    /// 每个测试独立隔离 pasteboard（knowledge entry 2026-05-29）
    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("ccb-test-paste-\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }

    /// 每个测试独立临时存储目录（防 ~/.buddy 污染）
    private func makeStorageDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-paste-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 场景3：四类型各自正确读取（det-machine 谓词）

    /// 场景3 文本：粘贴板写 string，触发读取后 snapshot 含对应 .text 条目，content == 原文
    ///
    /// Mutation-Survival 自检：
    /// - 不读取 .string mutant → snapshot 空 → precondition XCTFail（捕获）
    /// - 读取但类型错（标 .file）mutant → item.type != .text → 本断言失败（捕获）
    /// - content 被截断 mutant → != 原文 → 本断言失败（捕获）
    func test_scenario3_textType_readAndSnapshot() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        pb.setString("hello-paste-text", forType: .string)

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()  // 触发单次读取（不走 Timer，反 flaky）

        let snap = svc.snapshot(filter: nil)
        let textItem = snap.first { $0.type == .text }
        XCTAssertNotNil(textItem, "场景3: snapshot 必须含 .text 类型条目（读取 string 类型）")
        XCTAssertEqual(textItem?.content, "hello-paste-text",
            "场景3 (mutation-killer): .text 条目 content 必须 == 原文，实际 \"\(textItem?.content ?? "nil")\"")
    }

    /// 场景3 图片：粘贴板写 PNG data，触发读取后 snapshot 含 .image 条目，imagePath 非空且含 hash
    ///
    /// 谓词：observe NSPasteboard.data(forType:.png) exists == true AND length > 0
    /// 此处断言服务侧：snapshot 含 .image 条目 + imagePath 落盘路径非空
    func test_scenario3_imageType_readAndSnapshot() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        // 最小合法 PNG（1x1 透明）—— 必须能被 NSImage 解码否则蓝队可能丢弃
        let png = minimalPNG()
        pb.setData(png, forType: .png)

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let imageItem = snap.first { $0.type == .image }
        XCTAssertNotNil(imageItem, "场景3: snapshot 必须含 .image 类型条目（读取 png 类型）")
        XCTAssertNotNil(imageItem?.imagePath,
            "场景3 (mutation-killer): .image 条目 imagePath 必须非空（图片落盘 ~/.buddy/clipboard-images/<sha8>.png）")
        // imagePath 应含 item.hash（<sha8>.png 命名约定，CONTRACT_AMBIGUOUS #6）
        if let item = imageItem, let path = item.imagePath {
            XCTAssertTrue(path.contains(item.hash),
                "场景3: imagePath(\"\(path)\") 必须含 item.hash(\"\(item.hash)\")，契约 <sha8>.png 命名")
        }
    }

    /// 场景3 文件路径：粘贴板写 public.file-url，触发读取后 snapshot 含 .file 条目，content == 文件路径
    func test_scenario3_fileType_readAndSnapshot() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let fileURL = URL(fileURLWithPath: "/tmp/test-ccb-file-\(UUID().uuidString).txt")
        pb.writeObjects([fileURL as NSURL])

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let fileItem = snap.first { $0.type == .file }
        XCTAssertNotNil(fileItem, "场景3: snapshot 必须含 .file 类型条目（读取 public.file-url 类型）")
        XCTAssertNotNil(fileItem?.content,
            "场景3 (mutation-killer): .file 条目 content 必须非空（存文件路径）")
        if let content = fileItem?.content {
            XCTAssertTrue(content.contains("test-ccb-file"),
                "场景3: .file 条目 content 必须 == 文件路径，实际 \"\(content)\"")
        }
    }

    /// 场景3 富文本：粘贴板写 public.html + 纯文本，触发读取后 snapshot 含 .html 条目
    ///
    /// 谓词：observe NSPasteboard.data(forType:.html) exists == true AND length > 0
    /// 此处断言服务侧：snapshot 含 .html 条目 + html 字段非空 + content 含纯文本 fallback
    func test_scenario3_htmlType_readAndSnapshot() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let html = "<b>rich-text-test</b>"
        let plain = "rich-text-test"
        pb.setString(html, forType: .html)
        pb.setString(plain, forType: .string)

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let htmlItem = snap.first { $0.type == .html }
        XCTAssertNotNil(htmlItem, "场景3: snapshot 必须含 .html 类型条目（读取 public.html 类型）")
        XCTAssertEqual(htmlItem?.html, html,
            "场景3 (mutation-killer): .html 条目 html 字段必须 == 原 HTML，实际 \"\(htmlItem?.html ?? "nil")\"")
        XCTAssertEqual(htmlItem?.content, plain,
            "场景3: .html 条目 content 必须 == 纯文本 fallback，实际 \"\(htmlItem?.content ?? "nil")\"")
    }

    // MARK: - 场景5.P1：ConcealedType（密码）排除（det-machine）

    /// 场景5.P1 [det-machine]: 历史所有条目 not contains 敏感原文
    ///
    /// Mutation-Survival 自检：
    /// - 不检查 ConcealedType mutant → 密码入历史 → 本断言失败（捕获）
    /// - 检查但放行 mutant → 密码条目存在 → 本断言失败（捕获）
    func test_scenario5_P1_concealedType_excluded() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let secret = "super-secret-password-123"
        pb.setString(secret, forType: .string)
        // 标记为 ConcealedType（密码管理器如 1Password 会设置此类型）
        pb.setString("", forType: NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType"))

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let leaked = snap.contains { $0.content.contains(secret) }
        XCTAssertFalse(leaked,
            "场景5.P1 (mutation-killer): ConcealedType 标记内容必须不入历史，但 snapshot 含敏感原文 \"\(secret)\"")
    }

    // MARK: - 场景5.P2：TransientType（临时）排除（det-machine）

    /// 场景5.P2 [det-machine]: 历史所有条目 not contains 临时原文
    func test_scenario5_P2_transientType_excluded() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let temp = "transient-selection-456"
        pb.setString(temp, forType: .string)
        // 标记为 TransientType（如临时选中内容）
        pb.setString("", forType: NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.TransientType"))

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let leaked = snap.contains { $0.content.contains(temp) }
        XCTAssertFalse(leaked,
            "场景5.P2 (mutation-killer): TransientType 标记内容必须不入历史，但 snapshot 含临时原文 \"\(temp)\"")
    }

    // MARK: - 场景5.P3：持久化文件不含敏感/临时（det-machine）

    /// 场景5.P3 [det-machine]: clipboard-history.json 内容 not contains 敏感 AND not contains 临时
    func test_scenario5_P3_persistedFileExcludesSensitive() throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        // 先落盘一条正常内容（保证文件存在，才能验证"不含敏感"）
        pb.clearContents(); pb.setString("normal-content-123", forType: .string)
        svc.readPasteboard()  // append + 落盘

        // 再复制 ConcealedType 敏感内容（应被排除，不入历史）
        let secret = "persisted-secret-789"
        pb.clearContents()
        pb.setString(secret, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType"))
        svc.readPasteboard()  // ConcealedType 排除，不入历史

        // 读取持久化文件内容，断言文件存在 + 不含敏感原文
        let jsonPath = dir.appendingPathComponent("clipboard-history.json")
        let exists = FileManager.default.fileExists(atPath: jsonPath.path)
        XCTAssertTrue(exists,
            "场景5.P3 precondition: 正常内容读取后应落盘 clipboard-history.json（场景4.P1 契约）")

        guard exists else { return }
        let data = try Data(contentsOf: jsonPath)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonString.contains(secret),
            "场景5.P3 (mutation-killer): 持久化文件必须不含 ConcealedType 敏感原文，但 JSON 含 \"\(secret)\"")
    }

    // MARK: - 场景6.P1 + P2：连续复制相同内容不重复（det-machine）

    /// 场景6.P1 [det-machine] + P2：连续复制相同内容 → 条目出现次数 == 1 + 总条目数差 == 0
    ///
    /// Mutation-Survival 自检：
    /// - 不去重 mutant → 2 条相同 → 出现次数 == 2 → 本断言失败（捕获）
    /// - 去重但新增 mutant → count 差 == 1 → 本断言失败（捕获）
    func test_scenario6_P1_P2_consecutiveDuplicate_dedup() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        // 第一次复制
        pb.clearContents()
        pb.setString("dup-content", forType: .string)
        svc.readPasteboard()

        let countAfterFirst = svc.snapshot(filter: nil).count
        XCTAssertEqual(countAfterFirst, 1,
            "场景6.P1 precondition: 首次复制后历史应 == 1 条，实际 \(countAfterFirst)")

        // 第二次复制相同内容（changeCount 变化触发去重逻辑）
        pb.clearContents()
        pb.setString("dup-content", forType: .string)
        svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        let occurrence = snap.filter { $0.content == "dup-content" }.count
        XCTAssertEqual(occurrence, 1,
            "场景6.P1 (mutation-killer): 连续复制相同内容后该内容出现次数必须 == 1（sha256 去重），实际 \(occurrence)")

        let countAfterSecond = snap.count
        XCTAssertEqual(countAfterSecond - countAfterFirst, 0,
            "场景6.P2 (mutation-killer): 连续复制相同内容后总条目数差必须 == 0，实际差 \(countAfterSecond - countAfterFirst)")
    }

    /// 非连续提队首：A → B → A，第三次 A 应提至队首而非新增（hash 命中非连续重复）
    ///
    /// 契约：sha256——非连续重复提至队首。
    /// Mutation-Survival 自检：
    /// - 不提队首 mutant → A 仍在原位 → first.content != "A-nonconsec" → 本断言失败（捕获）
    /// - 新增而非提队 mutant → count == 3 → 本断言失败（捕获）
    func test_nonConsecutiveDuplicate_promotesToHead() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        pb.clearContents(); pb.setString("A-nonconsec", forType: .string); svc.readPasteboard()
        pb.clearContents(); pb.setString("B-nonconsec", forType: .string); svc.readPasteboard()
        // 此时顺序应为 [B, A]（最新在前）
        XCTAssertEqual(svc.snapshot(filter: nil).first?.content, "B-nonconsec",
            "非连续去重 precondition: 复制 B 后首条应为 B")

        // 第三次再复制 A（非连续重复）→ 应提至队首
        pb.clearContents(); pb.setString("A-nonconsec", forType: .string); svc.readPasteboard()

        let snap = svc.snapshot(filter: nil)
        XCTAssertEqual(snap.first?.content, "A-nonconsec",
            "非连续重复 (mutation-killer): A 再复制后必须提至队首，实际首条 \"\(snap.first?.content ?? "nil")\"")
        let aCount = snap.filter { $0.content == "A-nonconsec" }.count
        XCTAssertEqual(aCount, 1,
            "非连续重复 (mutation-killer): A 提队首而非新增，出现次数必须 == 1，实际 \(aCount)")
    }

    // MARK: - 边界值谓词：文本 ≤500 / 图片 ≤50 / 30 天过期

    /// 边界值谓词：textItems.count <= 500
    ///
    /// 注意：构造 501 个 distinct 文本复制可能慢。本测试用 501 次注入验证裁剪逻辑——
    /// 若蓝队实现用 prefix(500) 则第 501 次写入触发裁剪，count == 500。
    /// CONTRACT_AMBIGUOUS: 裁剪策略（FIFO 丢最旧 vs LRU）契约未明示。断言 count <= 500（边界值不变量），
    /// 不强断言具体保留哪些条目（防实现细节绑死）。
    func test_boundary_textItemsLimit_500() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        // 注入 501 个 distinct 文本
        for i in 0..<501 {
            pb.clearContents()
            pb.setString("limit-test-\(i)", forType: .string)
            svc.readPasteboard()
        }

        let snap = svc.snapshot(filter: nil)
        let textCount = snap.filter { $0.type == .text }.count
        XCTAssertLessThanOrEqual(textCount, 500,
            "边界值 (mutation-killer): textItems.count 必须 <= 500，实际 \(textCount)")
    }

    /// 边界值谓词：imageItems.count <= 50
    func test_boundary_imageItemsLimit_50() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        let png = minimalPNG()

        // 注入 51 个 distinct 图片（需 hash 不同 → 用 distinct PNG data 或蓝队若按像素 hash 需 distinct 图）
        // 这里用 distinct 字节确保 sha256 不同
        for i in 0..<51 {
            var data = png
            data.append(contentsOf: [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)])  // 后缀 distinct 字节
            pb.clearContents()
            pb.setData(data, forType: .png)
            svc.readPasteboard()
        }

        let snap = svc.snapshot(filter: nil)
        let imageCount = snap.filter { $0.type == .image }.count
        XCTAssertLessThanOrEqual(imageCount, 50,
            "边界值 (mutation-killer): imageItems.count 必须 <= 50，实际 \(imageCount)")
    }

    /// 边界值谓词：item.ts > now - 30*86400（30 天过期）
    ///
    /// 策略：构造一个预置过期条目（ts = now - 31 天），调 snapshot 验证被过滤。
    /// CONTRACT_AMBIGUOUS #3: 假定 snapshot 内部做过期过滤；若蓝队仅启动时清理而不在 snapshot 过滤，
    /// 此测试需调整为调 startMonitoring 后等待清理——但那依赖 Timer（flaky）。
    /// 按"snapshot 是对外读取 seam，应保证返回有效数据"原则断言 snapshot 不含过期条目。
    func test_boundary_expiry_30days_filtered() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        // 先放一条新条目（有效）
        pb.clearContents(); pb.setString("fresh-content", forType: .string); svc.readPasteboard()
        let freshCount = svc.snapshot(filter: nil).count
        XCTAssertEqual(freshCount, 1, "过期测试 precondition: 新条目应入历史")

        // 构造一条 31 天前的过期条目（通过 JSON 预置，CONTRACT_AMBIGUOUS：需蓝队暴露 load seam 或直接写 JSON）
        // 退路：若蓝队 load 是 internal，直接写 clipboard-history.json 然后 new 一个 service 触发 load
        let thirtyOneDaysAgo = Int(Date().timeIntervalSince1970) - 31 * 86400
        let expiredJSON = """
        {"schemaVersion":1,"items":[{"id":"expired-id","type":"text","content":"expired-31d","html":null,"imagePath":null,"sourceApp":null,"ts":\(thirtyOneDaysAgo),"hash":"expired1"}]}
        """
        let jsonPath = dir.appendingPathComponent("clipboard-history.json")
        try? expiredJSON.write(to: jsonPath, atomically: true, encoding: .utf8)

        // 重新构造触发 load
        let svc2 = ClipboardHistoryService(pasteboard: pb, storageDir: dir)

        let snap = svc2.snapshot(filter: nil)
        let expiredPresent = snap.contains { $0.content == "expired-31d" }
        XCTAssertFalse(expiredPresent,
            "边界值 (mutation-killer): 30 天前条目必须被过期过滤（ts > now - 30*86400），但 snapshot 含过期条目")
    }

    // MARK: - 场景4.P1 + P2 + P3：JSON 往返（持久化恢复）

    /// 场景4.P1 [det-machine] + P3：持久化文件存在 + 重启后首条 == 重启前首条
    /// 场景4.P2 [det-machine]: 重启后条目数 == 重启前条目数
    ///
    /// Mutation-Survival 自检：
    /// - 不落盘 mutant → 重启后 snapshot 空 → 本断言失败（捕获）
    /// - schema 不兼容 mutant → load 失败 → snapshot 空（或蓝队吞错）→ 本断言失败（捕获）
    func test_scenario4_P1_P2_P3_jsonRoundTrip() throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        // 第一阶段：写入 3 条 distinct 文本
        let svc1 = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("roundtrip-1", forType: .string); svc1.readPasteboard()
        pb.clearContents(); pb.setString("roundtrip-2", forType: .string); svc1.readPasteboard()
        pb.clearContents(); pb.setString("roundtrip-3", forType: .string); svc1.readPasteboard()

        let snapBefore = svc1.snapshot(filter: nil)
        let countBefore = snapBefore.count
        let firstBefore = snapBefore.first?.content

        // 场景4.P1：文件存在 + size > 0
        let jsonPath = dir.appendingPathComponent("clipboard-history.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath.path),
            "场景4.P1: clipboard-history.json 必须存在")
        let attrs = try FileManager.default.attributesOfItem(atPath: jsonPath.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0,
            "场景4.P1 (mutation-killer): clipboard-history.json size 必须 > 0，实际 \(size)")

        // 第二阶段：重新构造（模拟重启）+ 显式 load 恢复持久化历史
        let svc2 = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        svc2.load()  // CONTRACT_AMBIGUOUS: init 不自动 load（生产由 startMonitoring 触发），测试显式加载
        let snapAfter = svc2.snapshot(filter: nil)

        // 场景4.P2：重启后条目数 == 重启前
        XCTAssertEqual(snapAfter.count, countBefore,
            "场景4.P2 (mutation-killer): 重启后条目数必须 == 重启前(\(countBefore))，实际 \(snapAfter.count)")

        // 场景4.P3：重启后首条 == 重启前首条
        XCTAssertEqual(snapAfter.first?.content, firstBefore,
            "场景4.P3 (mutation-killer): 重启后首条必须 == 重启前首条(\"\(firstBefore ?? "nil")\")，实际 \"\(snapAfter.first?.content ?? "nil")\"")
    }

    /// schemaVersion == 1 契约：持久化 JSON 含 schemaVersion 字段且值 == 1
    func test_jsonSchemaVersion_is1() throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("schema-test", forType: .string); svc.readPasteboard()

        let jsonPath = dir.appendingPathComponent("clipboard-history.json")
        let data = try Data(contentsOf: jsonPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schemaVersion = json?["schemaVersion"] as? Int
        XCTAssertEqual(schemaVersion, 1,
            "契约 (mutation-killer): JSON schemaVersion 必须 == 1，实际 \(schemaVersion ?? -1)")
    }

    // MARK: - snapshot(filter:) 过滤谓词

    /// snapshot(filter:) 含过滤词的条目优先 / 仅返回匹配（契约：PastePlugin 调用支持过滤词）
    ///
    /// CONTRACT_AMBIGUOUS: filter 语义契约写"按 query 剩余词过滤"，但匹配方式（contains / prefix / fuzzy）未明示。
    /// 本测试断言 contains（最宽松），且 filter == nil 返回全部。
    /// 若蓝队用 prefix，"filter: github" 在 content="github-pr" 时仍匹配，但在 content="my-github" 时不匹配——
    /// 本测试用 content="github-repo" + filter="github" 确保 contains 与 prefix 均匹配（防歧义绑定）。
    func test_snapshot_filter_returnsMatching() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("github-repo-match", forType: .string); svc.readPasteboard()
        pb.clearContents(); pb.setString("unrelated-content", forType: .string); svc.readPasteboard()

        let filtered = svc.snapshot(filter: "github")
        let all = svc.snapshot(filter: nil)

        XCTAssertGreaterThanOrEqual(all.count, 2,
            "snapshot(filter:nil) precondition: 应返回全部条目（>= 2）")
        XCTAssertTrue(filtered.contains { $0.content.contains("github") },
            "snapshot(filter: \"github\") (mutation-killer): 必须返回含 github 的条目")
        XCTAssertFalse(filtered.contains { !$0.content.contains("github") },
            "snapshot(filter: \"github\"): 不应返回不含 github 的条目（若 filter 是严格过滤）")
    }

    // MARK: - startMonitoring 幂等谓词

    /// startMonitoring() 幂等：多次调用不崩溃、不重复注册 Timer
    ///
    /// 契约：startMonitoring() 启动 Timer 轮询，幂等。
    /// 此测试不依赖 Timer 实际触发（flaky），只验证幂等性（多次调用安全）。
    func test_startMonitoring_idempotent_multipleCallsNoCrash() {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let svc = ClipboardHistoryService(pasteboard: pb, storageDir: dir)
        XCTAssertNoThrow(svc.startMonitoring(),
            "startMonitoring() 首次调用不应抛错")
        XCTAssertNoThrow(svc.startMonitoring(),
            "startMonitoring() 第二次调用（幂等）不应抛错")
        XCTAssertNoThrow(svc.startMonitoring(),
            "startMonitoring() 第三次调用（幂等）不应抛错")
    }

    // MARK: - Helpers

    /// 最小合法 1x1 透明 PNG（8 字节签名 + IHDR + IDAT + IEND）
    private func minimalPNG() -> Data {
        // 已知的 1x1 透明 PNG 完整字节（67 字节）
        return Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
    }

    // MARK: - ISOLATION（源码扫描留 QA 核对）

    // ISOLATION: 蓝队实现信息隔离，ClipboardHistoryService.swift 源码扫描留 QA 核对。
    // 本红队测试不读取 Paste/ 下任何实现文件（信息隔离铁律），
    // 故无法在测试中断言其不 import Scene/Session/EventBus。
    // QA 阶段应补充源码扫描测试（镜像 AppLauncherIsolationAcceptanceTests 风格），
    // 断言 Launcher/Builtin/Paste/ 下 .swift 文件不引用像素猫符号。
    // 此处仅以注释形式预注册该验收点，不编写会读实现的测试。
}
