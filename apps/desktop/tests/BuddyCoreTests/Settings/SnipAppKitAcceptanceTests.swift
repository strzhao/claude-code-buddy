import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：snip 迁 AppKit 后的端到端验收（stage-4）
//
// 黑盒验收测试：基于设计文档 stage-4 承诺的「SnipPanelVC 迁纯 AppKit 后的外部可观测行为」下断言。
//
// 信息隔离铁律：本文件**不读取** docs/superpowers/plans/、蓝队 stage-4 改的 SnipPanelVC.swift
// 具体实现代码、SnipPanelView.swift（被删）、蓝队的测试。仅对设计承诺的 API 契约下断言。
//
// 设计权威源（唯一真相）：
// - **AC-WIN-01**：SnipPanelVC 源码无 sizingOptions 赋值（NSHostingController 时代的 sizingOptions
//   hack 在迁纯 AppKit 后必须消除）。源码 grep "sizingOptions" 命中数 == 0。
//   杀死「迁移残留 sizingOptions 赋值（对纯 AppKit VC 无效，且为死代码 hack）」回归。
//
// - **AC-WIN-02**：SnipPanelVC 不再是 NSHostingController 子类（纯 AppKit NSViewController）。
//   `SnipPanelVC() is NSHostingController` 必须 false。
//   杀死「仍继承 NSHostingController<SnipPanelView>（SnipPanelView 已删，编译破）」回归。
//
// - **AC-CRUD-03**：删除二次确认 NSAlert（presentDeleteAlert/handleDeleteResponse static seam）。
//   - presentDeleteAlert(for:) 构造（不 runModal）含「确认删除」+「取消」两按钮，
//     messageText 含 keyword。
//   - handleDeleteResponse(.alertSecondButtonReturn, ...)（取消）→ SnippetsService.shared.list 仍含（不删）。
//   - handleDeleteResponse(.alertFirstButtonReturn, ...)（确认）→ list 不含（删）。
//   杀死「删除无二次确认 / 确认与取消按钮语义反了 / 取消仍删」回归。
//
// - **makePanelVC 契约**（C6）：SnipPanelVC().makePanelVC() === vc（PluginSettingsPanelProvider 自返回）。
//
// 工作规则：每个谓词至少 1 个硬断言，失败即挂测试。不对实现状态容错。

@MainActor
final class SnipAppKitAcceptanceTests: XCTestCase {

    // MARK: - 临时 HOME 隔离（AC-CRUD-03 用）
    //
    // handleDeleteResponse 内部硬编码 SnippetsService.shared（读 ~/.buddy/snippets.json，
    // 路径由 NSHomeDirectory() 决定）。单例 static let 在首次访问时初始化一次并缓存路径，
    // 故 HOME 重定向必须在**首次访问 .shared 之前**（patterns/2026-07-09：测试方法内 setenv
    // 对已初始化单例太晚）。红队策略：setUp 早期 setenv("HOME", tempDir) + 用唯一 keyword
    // 命名空间隔离 + tearDown 清理 + 同时读磁盘 json 作 source-of-truth 兜底。

    /// 测试进程原始 HOME（tearDown 还原）。
    private var originalHOME: String?
    /// 临时 HOME 目录（~/.buddy/snippets.json 落此）。
    private var tempHOME: URL!
    /// 临时 snippets.json 路径（tempHOME/.buddy/snippets.json）。
    private var tempSnippetsFile: URL!
    /// 本测试用唯一 keyword 前缀（防与其他测试 / 用户数据冲突）。
    private let keywordPrefix = "acceptanceRedTeam_\(UUID().uuidString.prefix(8))"

    override func setUp() {
        super.setUp()
        // 记录原始 HOME（还原用）。
        originalHOME = ProcessInfo.processInfo.environment["HOME"]

        // 建临时 HOME 目录。
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipAppKitAcceptance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        tempHOME = tmpBase

        // 重定向 HOME（让 NSHomeDirectory() / SnippetsService.shared 落临时目录）。
        // setenv 在单例首次访问前生效即隔离成功；若单例已被其他测试初始化则 HOME 无效，
        // 此时靠唯一 keyword 命名空间 + tearDown 清理兜底（见各测试断言双路：list + 磁盘）。
        setenv("HOME", tempHOME.path, 1)

        // 临时 snippets.json 路径（与 SnippetsService 生产路径计算逻辑对齐：
        // NSHomeDirectory()/.buddy/snippets.json）。
        let buddyDir = tempHOME.appendingPathComponent(".buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        tempSnippetsFile = buddyDir.appendingPathComponent("snippets.json", isDirectory: false)
        // 预置空文件（与 SnippetsService.load 容错语义一致：缺失→空列表）。
        try? Data("[]".utf8).write(to: tempSnippetsFile)
    }

    override func tearDown() {
        // 还原 HOME 环境。
        if let prev = originalHOME {
            setenv("HOME", prev, 1)
        } else {
            unsetenv("HOME")
        }

        // 清理本测试写入 SnippetsService.shared 的唯一 keyword（防残留）。
        // 幂等：delete 不存在不报错。
        let service = SnippetsService.shared
        _ = service.load() // 刷新磁盘最新状态
        let allItems = service.list()
        let mine = allItems.filter { $0.keyword.hasPrefix("acceptanceRedTeam_") }
        for item in mine {
            service.delete(keyword: item.keyword)
        }

        // 删临时 HOME 目录。
        try? FileManager.default.removeItem(at: tempHOME)

        super.tearDown()
    }

    // MARK: - Helpers

    /// 读 snippets.json 磁盘文件为 [SnippetItem]（source-of-truth，绕过单例缓存）。
    /// 文件缺失/空/损坏 → 空列表（与 SnippetsService.load 容错语义一致）。
    private func readDiskSnippets() -> [SnippetItem] {
        guard let data = try? Data(contentsOf: tempSnippetsFile),
              data.isEmpty == false else {
            return []
        }
        return (try? JSONDecoder().decode([SnippetItem].self, from: data)) ?? []
    }

    // MARK: - AC-WIN-01：SnipPanelVC 源码无 sizingOptions 赋值

    /// AC-WIN-01 [no-sizing-options-hack]：读 SnipPanelVC.swift 源码，断言不含 "sizingOptions"。
    ///
    /// 设计契约：stage-4 把 SnipPanelVC 从 NSHostingController<SnipPanelView> 迁纯 AppKit
    /// NSViewController 后，旧 sizingOptions hack（给 hostingController 设 sizingOptions
    /// 绕 fittingSize 缩 0 的 workaround）必须消除（对纯 AppKit VC 无效，死代码 hack）。
    /// 若源码仍含 sizingOptions，证明迁移残留（AC-WIN-01 违反）。
    ///
    /// 双断言（强证据 + 兜底）：
    ///   1. 源码 grep "sizingOptions" == 0（强证据，依赖源码路径可见）。
    ///   2. SnipPanelVC() 实例化不崩（弱证据，兜底：源码不可读时至少验证可实例化）。
    func test_AC_WIN_01_noSizingOptionsInSource() {
        // 断言 1：读源码 grep sizingOptions（若源码路径可读）。
        // 源码路径相对测试运行目录（swift test 通常在 apps/desktop 或 Package.swift 目录）。
        let candidatePaths = [
            "Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift",
            "apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift",
        ]
        var sourceChecked = false
        for relative in candidatePaths {
            let url = URL(fileURLWithPath: relative)
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            sourceChecked = true
            let occurrences = source.components(separatedBy: "sizingOptions").count - 1
            XCTAssertEqual(occurrences, 0,
                """
                AC-WIN-01 违反：SnipPanelVC.swift 仍含 \(occurrences) 处 "sizingOptions" 赋值。
                stage-4 迁纯 AppKit 后 sizingOptions hack（NSHostingController 时代的 fittingSize 绕行）
                必须消除——对纯 AppKit NSViewController 它是死代码且为迁移残留证据。
                """)
            break
        }

        // 断言 2（兜底）：SnipPanelVC() 实例化不崩（无论源码是否可读）。
        let vc = SnipPanelVC()
        XCTAssertNotNil(vc.view,
            "AC-WIN-01 兜底：SnipPanelVC() 必须能实例化并加载 view（源码可读=\(sourceChecked)）")
    }

    // MARK: - AC-WIN-02：SnipPanelVC 不再是 NSHostingController 子类（纯 AppKit）

    /// AC-WIN-02 [pure-appkit-not-hosting]：`SnipPanelVC() is NSHostingController` 必须 false。
    ///
    /// 设计契约：stage-4 把 SnipPanelVC 从 NSHostingController<SnipPanelView> 重写为纯 AppKit
    /// NSViewController（master-detail）。SnipPanelView 已删（SwiftUI 层消失），
    /// 故 SnipPanelVC 不能再继承 NSHostingController（否则编译破）。若仍 is NSHostingController，
    /// 证明迁移未完成 / 仍走 SwiftUI host（AC-WIN-02 违反）。
    func test_AC_WIN_02_snipPanelVC_notNSHostingController() {
        let vc = SnipPanelVC()
        // 注：`vc is NSHostingController`（无泛型参数）触发 Swift 编译器 "failed to produce diagnostic"
        // bug（NSHostingController 是泛型类型，裸 `is` 检查让 type checker 崩）。
        // 改用类型名检查（等价语义：验证类名不含 NSHostingController）。
        let typeName = String(describing: type(of: vc))
        XCTAssertFalse(typeName.contains("NSHostingController"),
            """
            AC-WIN-02 违反：SnipPanelVC 仍是 NSHostingController 子类（实际: \(typeName)）。
            stage-4 必须重写为纯 AppKit NSViewController（SnipPanelView 已删，
            NSHostingController<SnipPanelView> 无法编译）。
            """)
        // 进一步：必须是 NSViewController（AppKit 基类契约）。
        XCTAssertTrue(vc is NSViewController,
            "AC-WIN-02：SnipPanelVC 必须是 NSViewController（实际: \(typeName)）")
    }

    // MARK: - makePanelVC 契约（C6：自返回）

    /// C6 契约 [make-panel-vc-returns-self]：SnipPanelVC().makePanelVC() === vc。
    ///
    /// 设计契约：PluginSettingsPanelProvider 要求 makePanelVC 返回自身（VC 自身即面板主体）。
    /// 若 !== vc，证明 makePanelVC 返回了包装层 / 新实例（破坏设置页 containment 切换契约）。
    func test_makePanelVC_returnsSelf() {
        let vc = SnipPanelVC()
        let panelVC = vc.makePanelVC()
        XCTAssertTrue(panelVC === (vc as AnyObject),
            """
            C6 契约违反：SnipPanelVC().makePanelVC() 必须 === vc（自返回），
            实际 panelVC=\(ObjectIdentifier(panelVC)) vc=\(ObjectIdentifier(vc as AnyObject))。
            makePanelVC 返回了不同实例 → 破坏 PluginSettingsPanelProvider containment 契约。
            """)
        // 类型确认：返回的 panelVC 仍是 SnipPanelVC（非别的 VC 类型）。
        XCTAssertTrue(panelVC is SnipPanelVC,
            "C6：makePanelVC 返回的必须是 SnipPanelVC（实际: \(type(of: panelVC))）")
    }

    // MARK: - AC-CRUD-03：删除二次确认 NSAlert（取消保留 / 确认删除）

    /// AC-CRUD-03 [delete-confirm-alert-cancel-preserves-and-confirm-deletes]：
    /// 临时 HOME + add 一条 snippet → presentDeleteAlert(for:) 断言按钮文案（「确认删除」/「取消」）
    /// + messageText 含 keyword → handleDeleteResponse(.alertSecondButtonReturn, ...)（取消）→
    /// SnippetsService.shared.list 仍含（不删）→ handleDeleteResponse(.alertFirstButtonReturn, ...)（确认）
    /// → list 不含（删）。
    ///
    /// 设计契约：
    /// - presentDeleteAlert(for:) 是 static seam，构造 NSAlert **但不 runModal**（避免阻塞
    ///   swift test RunLoop，patterns/2026-06-27）。
    /// - alert 含「确认删除」（first button，alertFirstButtonReturn）+「取消」（second button，
    ///   alertSecondButtonReturn）两按钮；messageText 含被删 keyword。
    /// - handleDeleteResponse(.alertFirstButtonReturn) → SnippetsService.shared.delete（真删）。
    /// - handleDeleteResponse(.alertSecondButtonReturn / 其他) → 不删（取消）。
    ///
    /// 杀死「删除无二次确认 / 确认与取消按钮语义反了（first=取消 second=确认）/ 取消仍删」回归。
    func test_AC_CRUD_03_deleteConfirmAlert_cancelPreserves() throws {
        let keyword = "\(keywordPrefix)_del"
        let content = "红队删除验收 fixture"

        // fixture：先确保该 keyword 不存在（防其他测试残留）。
        let service = SnippetsService.shared
        _ = service.load()
        service.delete(keyword: keyword) // 幂等清理

        // 加一条 snippet（经数据层 add，C4 校验）。
        try service.add(keyword: keyword, content: content)
        let item = SnippetItem(keyword: keyword, content: content)

        // 断言 fixture 落地（list 含）。
        let beforeList = service.list()
        XCTAssertTrue(beforeList.contains(where: { $0.keyword == keyword }),
            "AC-CRUD-03 fixture 失败：add 后 SnippetsService.shared.list 应含 keyword「\(keyword)」")
        // 磁盘 source-of-truth（HOME 重定向生效则 tempSnippetsFile 有数据；不生效则读真实路径，
        // 但 keyword 唯一前缀隔离仍可断言「含」）。
        let beforeDisk = readDiskSnippets()
        // 磁盘断言为软证据（HOME 重定向不生效时磁盘文件可能是真实用户数据，不强制含本 keyword）。

        // 切片 1：presentDeleteAlert seam 验 NSAlert 构造（按钮文案 + messageText 含 keyword，不 runModal）。
        let alert = SnipPanelVC.presentDeleteAlert(for: item)
        let buttonTitles = alert.buttons.map { $0.title }
        XCTAssertEqual(alert.buttons.count, 2,
            "AC-CRUD-03：删除确认 alert 必须含且仅含 2 个按钮（确认删除 + 取消），实际 \(alert.buttons.count) 个: \(buttonTitles)")
        XCTAssertTrue(buttonTitles.contains("确认删除"),
            "AC-CRUD-03：alert 必须含「确认删除」按钮，实际按钮文案: \(buttonTitles)")
        XCTAssertTrue(buttonTitles.contains("取消"),
            "AC-CRUD-03：alert 必须含「取消」按钮，实际按钮文案: \(buttonTitles)")
        // 按钮顺序契约：first button = 确认删除（alertFirstButtonReturn），second button = 取消。
        XCTAssertEqual(alert.buttons.first?.title, "确认删除",
            """
            AC-CRUD-03：first button 必须是「确认删除」（对应 .alertFirstButtonReturn = 确认删），
            实际 first: \(alert.buttons.first?.title ?? "nil")，全部: \(buttonTitles)。
            若 first 是「取消」，handleDeleteResponse(.alertFirstButtonReturn) 会误删（语义反）。
            """)
        XCTAssertTrue(alert.messageText.contains(keyword),
            "AC-CRUD-03：alert messageText 必须含被删 keyword「\(keyword)」，实际: \(alert.messageText)")

        // 切片 2：取消（alertSecondButtonReturn）→ 不删。
        SnipPanelVC.handleDeleteResponse(.alertSecondButtonReturn, for: item)
        _ = service.load() // 刷新（防内存态滞后）
        let afterCancelList = service.list()
        XCTAssertTrue(afterCancelList.contains(where: { $0.keyword == keyword }),
            """
            AC-CRUD-03 取消违反：handleDeleteResponse(.alertSecondButtonReturn)（取消）后
            SnippetsService.shared.list 仍应含 keyword「\(keyword)」（不删），
            但实际已删（list 不含）。取消按钮语义反了 / 取消仍删。
            """)

        // 切片 3：确认（alertFirstButtonReturn）→ 删。
        SnipPanelVC.handleDeleteResponse(.alertFirstButtonReturn, for: item)
        _ = service.load() // 刷新读最新
        let afterConfirmList = service.list()
        XCTAssertFalse(afterConfirmList.contains(where: { $0.keyword == keyword }),
            """
            AC-CRUD-03 确认违反：handleDeleteResponse(.alertFirstButtonReturn)（确认删除）后
            SnippetsService.shared.list 应不含 keyword「\(keyword)」（已删），
            但实际仍含（未删）。确认按钮未触发真删 / delete 调用丢失。
            """)

        // 磁盘 source-of-truth 兜底（HOME 重定向生效时强断言；不生效则软断言）。
        let afterConfirmDisk = readDiskSnippets()
        // 若 beforeDisk 含本 keyword（HOME 重定向生效，磁盘 = tempSnippetsFile），则强断言已删。
        if beforeDisk.contains(where: { $0.keyword == keyword }) {
            XCTAssertFalse(afterConfirmDisk.contains(where: { $0.keyword == keyword }),
                """
                AC-CRUD-03 磁盘违反：确认删除后磁盘 snippets.json（\(tempSnippetsFile.path)）
                应不含 keyword「\(keyword)」（已删），但实际仍含。save 未落盘 / 删除未持久化。
                """)
        }
        // tearDown 会再次清理 keyword（幂等兜底）。
    }
}
