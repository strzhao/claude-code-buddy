import AppKit
import XCTest
@testable import BuddyCore

// MARK: - ScreenshotPluginAcceptanceTests
//
// 红队验收测试：ScreenshotPlugin 截屏命令契约（ACC-SCREENSHOT-1..5 + C-* 契约）
//
// 切片范围：本轮仅测「区域选择 + 复制」切片（原生 SCScreenshotManager，无 Capso）。
// 标注/overlay 视觉/e2e 真机不在本切片（延后）。本文件只测：
//   - ACC-SCREENSHOT-1     — 候选路由：actions(for:"截屏") 非空含 id "screenshot"
//   - C-SCREENSHOT-KEYWORDS — {截屏,screenshot,jietu,截图} 各产出；无关词不产出
//   - C-PRIORITY            — priority == 90（独立档位，不与 SystemCommand 100 / Paste 150 / Calculator 200 / AppLauncher 0 冲突）
//   - C-REGISTRY-REGISTER   — 注册到 BuiltinPluginRegistry（init + reset 均含；防 flaky）
//   - C-CAPTURE-SEAM        — ScreenCapturing 协议可注入 Mock；不真捕屏
//   - C-COPY-SEAM           — CopyService 注入命名 pasteboard；handleConfirm 后读实际 PNG 内容
//   - ACC-SCREENSHOT-3      — handleConfirm(rect)：overlay 确认 → captureArea(rect) → copyImage(data)（perform 仅 present overlay，捕获在 onConfirm→handleConfirm）
//   - ACC-SCREENSHOT-5      — overlay 取消：不调 captureArea、不写剪贴板
//   - 权限降级              — capture seam 抛 denied → handleConfirm 不崩、不写剪贴板
//   - EnabledStore 开关     — setEnabled(id:"screenshot", false) → 不产出候选
//
// 红队红线（信息隔离）：
//   - 绝不 Read apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Screenshot/ 下任何 .swift
//   - 仅依据设计文档 ## 契约规约 + ## 验收场景 + 公开 BuiltinPlugin/CopyService 协议断言
//   - 全走 seam mock：不真捕屏、不真写系统剪贴板、不触发 TCC
//
// CONTRACT_AMBIGUOUS（设计文档内部冲突，已裁定）：
//   1. priority：## 契约规约 + task 描述写 90；## 设计文档 架构章节写 100。
//      → 以 ## 契约规约（合同）的 90 为准（独立档位无冲突，更安全）。
//   2. CopyService seam 形态：设计契约写 `CopyServiceProtocol`，但既有 CopyService 是
//      `final class`（非协议），Calculator/Paste 测试用 `CopyService(pasteboard:)` 注入命名 pb。
//      → 本测试用既有最稳形态：注入 `CopyService(pasteboard: 命名pb)`。
//        若蓝队引入 `CopyServiceProtocol`，将此处 copy 参数类型泛化为该协议即可
//        （但优先按既有约定，与 Calculator/Paste 同款，零迁移成本）。
//   3. ScreenshotPlugin 注入构造器：假设 `init(capture: ScreenCapturing, copy: CopyService, ...)`
//      （对齐 SystemCommand(locker:)/Calculator(copyService:) 注入模式）。
//      若蓝队实际签名不同（如参数名/顺序/是否含权限 seam），以蓝队公开签名为准调整 mock 注入，
//      仍不读实现内部逻辑。
//   4. ScreenCapturing.captureArea 返回 Data（PNG）。生产实现封装 SCScreenshotManager；
//      Mock 返回固定 PNG Data 即可。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// MARK: - Mock：ScreenCapturing spy（记录调用 + 固定 PNG）
//
// **nonisolated**（非 @MainActor）：performCaptureSync 用 detached task 调 captureArea，
// 非 @MainActor 隔离的 mock 无需 actor hop，detached task 立即执行 → 不死锁。
// （生产 SCScreenCapture 是 @MainActor struct，走真机 overlay 路径，不在此 mock 覆盖）

/// spy mock：记录 captureArea 调用次数 + 收到的 rect，返回固定 PNG Data，不真捕屏
private final class CaptureSpy: ScreenCapturing {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastRect: CGRect?
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastRect: CGRect? { lock.lock(); defer { lock.unlock() }; return _lastRect }
    /// 固定 PNG（1x1 透明像素签名 + IHDR 占位，足以被 copyImage 字节比对）
    let stubPNG = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,  // PNG signature
    ])

    func captureArea(_ rect: CGRect) async throws -> Data {
        lock.lock()
        _callCount += 1
        _lastRect = rect
        lock.unlock()
        return stubPNG
    }
}

/// stub mock：captureArea 抛权限拒绝（模拟 TCC 未授权）
private struct PermissionDeniedCapture: ScreenCapturing {
    func captureArea(_ rect: CGRect) async throws -> Data {
        throw LauncherError.systemCommandFailed("屏幕录制权限未授予")
    }
}

// MARK: - 辅助：构造隔离 pasteboard + CopyService（不写系统剪贴板）

@MainActor
private func makeIsolatedCopyService() -> (CopyService, NSPasteboard) {
    let pb = NSPasteboard(name: NSPasteboard.Name("ccb-test-screenshot-\(UUID().uuidString)"))
    pb.clearContents()
    return (CopyService(pasteboard: pb), pb)
}

// MARK: - ACC-SCREENSHOT-1 / C-SCREENSHOT-KEYWORDS：属性契约 + 关键词路由

@MainActor
final class ScreenshotPluginAttributeAcceptanceTests: XCTestCase {

    // MARK: 属性契约（ACC-SCREENSHOT-1 precondition）

    /// ACC-SCREENSHOT-1: ScreenshotPlugin.id == "screenshot"
    func test_ACC1_id_screenshot() {
        let plugin = ScreenshotPlugin.shared
        XCTAssertEqual(plugin.id, "screenshot",
            "ACC-SCREENSHOT-1: ScreenshotPlugin.id 必须 == \"screenshot\"，实际 \"\(plugin.id)\"")
    }

    /// C-PRIORITY: ScreenshotPlugin.priority == 90（独立档位）
    func test_CPRIORITY_priority_equals90() {
        let plugin = ScreenshotPlugin.shared
        XCTAssertEqual(plugin.priority, 90,
            "C-PRIORITY: ScreenshotPlugin.priority 必须 == 90（契约规约；独立档位），实际 \(plugin.priority)")
    }

    /// ACC-SCREENSHOT-1: sectionTitle 含「截屏」
    func test_ACC1_sectionTitle_containsScreenshot() {
        let plugin = ScreenshotPlugin.shared
        XCTAssertTrue(plugin.sectionTitle.contains("截屏"),
            "ACC-SCREENSHOT-1: sectionTitle 必须含 \"截屏\"，实际 \"\(plugin.sectionTitle)\"")
    }

    /// ACC-SCREENSHOT-1: 遵守 BuiltinPlugin 协议
    func test_ACC1_conformsTo_BuiltinPlugin() {
        let plugin: any BuiltinPlugin = ScreenshotPlugin.shared
        XCTAssertEqual(plugin.id, "screenshot")
        XCTAssertEqual(plugin.priority, 90)
    }

    // MARK: C-PRIORITY：与既有内置插件无档位冲突

    /// C-PRIORITY: screenshot(90) 与 SystemCommand(100) 不同档
    func test_CPRIORITY_distinctFrom_systemCommand_100() {
        XCTAssertNotEqual(ScreenshotPlugin.shared.priority, SystemCommandPlugin.shared.priority,
            "C-PRIORITY: screenshot priority(\(ScreenshotPlugin.shared.priority)) 不应等于 SystemCommand(\(SystemCommandPlugin.shared.priority))")
    }

    /// C-PRIORITY: screenshot(90) 与 Calculator(200) 不同档
    func test_CPRIORITY_distinctFrom_calculator_200() {
        XCTAssertNotEqual(ScreenshotPlugin.shared.priority, CalculatorPlugin.shared.priority,
            "C-PRIORITY: screenshot priority 不应等于 Calculator(\(CalculatorPlugin.shared.priority))")
    }

    /// C-PRIORITY: screenshot(90) 与 AppLauncher(0) 不同档
    func test_CPRIORITY_distinctFrom_appLauncher_0() {
        XCTAssertNotEqual(ScreenshotPlugin.shared.priority, AppLauncherPlugin.shared.priority,
            "C-PRIORITY: screenshot priority 不应等于 AppLauncher(\(AppLauncherPlugin.shared.priority))")
    }

    /// C-PRIORITY: screenshot(90) 与 Paste(150) 不同档（若 Paste 已注册）
    func test_CPRIORITY_distinctFrom_paste_150() {
        // PastePlugin.priority 契约为 150（见 CLAUDE.md 内置插件体系）
        XCTAssertNotEqual(ScreenshotPlugin.shared.priority, 150,
            "C-PRIORITY: screenshot priority 不应等于 Paste(150)")
    }
}

@MainActor
final class ScreenshotPluginKeywordAcceptanceTests: XCTestCase {

    // MARK: C-SCREENSHOT-KEYWORDS：四个关键词各产出 screenshot 候选

    /// C-SCREENSHOT-KEYWORDS: query=="截屏" → 含 id "screenshot" 候选
    func test_KEYWORDS_截屏_producesScreenshotCandidate() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "截屏")

        XCTAssertTrue(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"截屏\" 必须产出 pluginId==\"screenshot\" 候选，实际 \(actions.map { $0.pluginId })")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="截图" → 含 id "screenshot" 候选
    func test_KEYWORDS_截图_producesScreenshotCandidate() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "截图")

        XCTAssertTrue(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"截图\" 必须产出 screenshot 候选，实际 \(actions.map { $0.pluginId })")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="screenshot" → 含 id "screenshot" 候选
    func test_KEYWORDS_screenshot_producesScreenshotCandidate() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "screenshot")

        XCTAssertTrue(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"screenshot\" 必须产出 screenshot 候选，实际 \(actions.map { $0.pluginId })")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="jietu" → 含 id "screenshot" 候选（拼音）
    func test_KEYWORDS_jietu_producesScreenshotCandidate() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "jietu")

        XCTAssertTrue(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"jietu\" 必须产出 screenshot 候选（拼音），实际 \(actions.map { $0.pluginId })")
    }

    // MARK: 大小写不敏感（对标 SystemCommand）

    /// C-SCREENSHOT-KEYWORDS: query=="SCREENSHOT" 大小写不敏感命中
    func test_KEYWORDS_SCREENSHOT_caseInsensitive() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "SCREENSHOT")

        XCTAssertTrue(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"SCREENSHOT\" 大小写不敏感应命中，实际 \(actions.map { $0.pluginId })")
    }

    // MARK: negate：不相关词不产出 screenshot 候选

    /// C-SCREENSHOT-KEYWORDS: query=="微信" 不产出 screenshot 候选
    func test_KEYWORDS_negate_weixin() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "微信")

        XCTAssertFalse(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"微信\" 不应产出 screenshot 候选")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="lock" 不产出 screenshot 候选（不与 system 命令冲突）
    func test_KEYWORDS_negate_lock() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "lock")

        XCTAssertFalse(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"lock\" 不应产出 screenshot 候选（关键词集与 system 无交集）")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="cat" 不产出 screenshot 候选
    func test_KEYWORDS_negate_cat() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "cat")

        XCTAssertFalse(actions.contains { $0.pluginId == "screenshot" },
            "C-SCREENSHOT-KEYWORDS: query==\"cat\" 不应产出 screenshot 候选")
    }

    /// C-SCREENSHOT-KEYWORDS: query=="" 空查询不产出
    func test_KEYWORDS_negate_emptyQuery() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "")

        XCTAssertTrue(actions.isEmpty,
            "C-SCREENSHOT-KEYWORDS: 空 query 必须返回 []，实际 \(actions.count) 条")
    }
}

// MARK: - ACC-SCREENSHOT-1 / 候选内容契约

@MainActor
final class ScreenshotPluginCandidateAcceptanceTests: XCTestCase {

    /// ACC-SCREENSHOT-1: query=="截屏" 产出的候选 title/subtitle 含截屏语义（非空）
    func test_ACC1_candidateTitle_nonEmpty_containsScreenshot() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "截屏")

        guard let action = actions.first(where: { $0.pluginId == "screenshot" }) else {
            XCTFail("ACC-SCREENSHOT-1 precondition: query==\"截屏\" 必须产出 screenshot 候选")
            return
        }
        XCTAssertFalse(action.title.isEmpty,
            "ACC-SCREENSHOT-1: screenshot 候选 title 不能为空")
        // title 或 subtitle 至少一处含「截屏」语义
        let combined = (action.title + (action.subtitle ?? ""))
        let hasScreenshotSemantics = combined.contains("截屏") || combined.contains("截")
        XCTAssertTrue(hasScreenshotSemantics,
            "ACC-SCREENSHOT-1: 候选 title/subtitle 应含截屏语义，实际 title=\"\(action.title)\" subtitle=\"\(action.subtitle ?? "nil")\"")
    }

    /// ACC-SCREENSHOT-1: 完全匹配 score > 前缀命中 score（对标 SystemCommand SC5）
    func test_ACC1_exactScore_greaterThan_prefixScore() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)

        let exactActions = await plugin.actions(for: "截屏")
        let prefixActions = await plugin.actions(for: "截")

        guard let exact = exactActions.first(where: { $0.pluginId == "screenshot" }),
              let prefix = prefixActions.first(where: { $0.pluginId == "screenshot" }) else {
            XCTFail("ACC-SCREENSHOT-1 precondition: \"截屏\" 和 \"截\" 都必须命中 screenshot")
            return
        }

        XCTAssertGreaterThan(exact.score, prefix.score,
            "ACC-SCREENSHOT-1: 完全匹配 score(\(exact.score)) 必须 > 前缀命中 score(\(prefix.score))")
    }
}

// MARK: - C-REGISTRY-REGISTER：注册到 BuiltinPluginRegistry

@MainActor
final class ScreenshotPluginRegistryAcceptanceTests: XCTestCase {

    /// C-REGISTRY-REGISTER: 默认 registry 含 screenshot 插件
    func test_CREGISTRY_defaultInit_containsScreenshot() {
        let registry = BuiltinPluginRegistry()
        XCTAssertTrue(registry.plugins.contains { $0.id == "screenshot" },
            "C-REGISTRY-REGISTER: 默认初始化的 Registry 必须含 screenshot 插件，实际 \(registry.plugins.map { $0.id })")
    }

    /// C-REGISTRY-REGISTER: reset() 后默认列表仍含 screenshot（防 flaky，init/reset 一致性）
    func test_CREGISTRY_reset_stillContainsScreenshot() {
        BuiltinPluginRegistry.shared.reset()
        XCTAssertTrue(BuiltinPluginRegistry.shared.plugins.contains { $0.id == "screenshot" },
            "C-REGISTRY-REGISTER (防 flaky): reset() 后默认列表必须仍含 screenshot，实际 \(BuiltinPluginRegistry.shared.plugins.map { $0.id })")
    }

    /// C-REGISTRY-REGISTER: 默认 registry 仲裁后 screenshot priority 90 落在正确档位
    /// （< SystemCommand 100 / Paste 150 / Calculator 200，> AppLauncher 0）
    func test_CREGISTRY_screenshotPriority_between_others() {
        let registry = BuiltinPluginRegistry()
        let priorities = Dictionary(uniqueKeysWithValues: registry.plugins.map { ($0.id, $0.priority) })

        guard let ssPriority = priorities["screenshot"] else {
            XCTFail("C-REGISTRY-REGISTER precondition: registry 必须含 screenshot")
            return
        }
        XCTAssertEqual(ssPriority, 90)

        // screenshot 低于 system/calculator/paste，高于 app-launcher
        if let sys = priorities["system-command"] { XCTAssertGreaterThan(sys, ssPriority) }
        if let calc = priorities["calculator"] { XCTAssertGreaterThan(calc, ssPriority) }
        if let app = priorities["app-launcher"] { XCTAssertLessThan(app, ssPriority) }
    }

    /// C-REGISTRY-REGISTER: registry.actions(for:"截屏") 含 screenshot 候选（端到端路由）
    func test_CREGISTRY_actionsFor_截屏_containsScreenshot() async {
        let registry = BuiltinPluginRegistry(plugins: [ScreenshotPlugin.shared])
        let result = await registry.actions(for: "截屏")

        XCTAssertTrue(result.contains { $0.pluginId == "screenshot" },
            "C-REGISTRY-REGISTER: registry.actions(for:\"截屏\") 必须含 screenshot 候选，实际 \(result.map { $0.pluginId })")
    }
}

// MARK: - C-CAPTURE-SEAM / C-COPY-SEAM / ACC-SCREENSHOT-3：seam 注入 + perform 流程

@MainActor
final class ScreenshotPluginSeamAcceptanceTests: XCTestCase {

    // MARK: 惰性执行：构造/actions 不触发 seam（对标 SystemCommand SC6）

    /// C-CAPTURE-SEAM: 构造 ScreenshotPlugin 不触发 captureArea
    func test_SEAM_construction_doesNotCapture() {
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        _ = ScreenshotPlugin(capture: spy, copy: copy)
        XCTAssertEqual(spy.callCount, 0,
            "C-CAPTURE-SEAM: 构造 ScreenshotPlugin 不应触发 captureArea，spy.callCount 应为 0")
    }

    /// C-CAPTURE-SEAM: actions(for:) 查询不触发 captureArea（惰性）
    func test_SEAM_actionsQuery_doesNotCapture() async {
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)
        _ = await plugin.actions(for: "截屏")
        XCTAssertEqual(spy.callCount, 0,
            "C-CAPTURE-SEAM: actions(for:) 不应触发 captureArea（惰性），spy.callCount 应为 0")
    }

    // MARK: ACC-SCREENSHOT-3：perform 流程 — overlay 确认 → capture → copyImage

    /// ACC-SCREENSHOT-3 / SC3': handleConfirm(rect) → captureArea 被调 + copyImage 写 PNG 到隔离 pasteboard
    ///
    /// **契约修正（auto-fix，原红队测 perform→直驱 capture 是错误契约）**：
    /// perform 同步只 present overlay（不捕获）；捕获在 overlay.onConfirm → handleConfirm 异步完成。
    /// 测试直接 `await plugin.handleConfirm(rect)` 确定性验证捕获+复制（不触发 overlay present GUI）。
    ///
    /// Mutation-Survival 自检：
    /// - handleConfirm no-op mutant → captureArea 未调 + pasteboard 空 → 失败（捕获）
    /// - 跳过 copyImage mutant → pasteboard 空 → 失败（捕获）
    /// - 用系统剪贴板 mutant → 隔离 pb 空 → 失败（捕获）
    func test_ACC3_handleConfirm_callsCaptureAndWritesPNG() async throws {
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        // handleConfirm 前：seam 未调、pasteboard 空
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertNil(pb.data(forType: .png))

        // 直接 await handleConfirm（overlay.onConfirm 的实现目标，确定性无 GUI）
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        await plugin.handleConfirm(rect)

        // 硬断言 1：captureArea 被调恰好一次，且收到正确 rect
        XCTAssertEqual(spy.callCount, 1,
            "ACC-SCREENSHOT-3 (mutation-killer): handleConfirm 后 captureArea 必须被调恰好 1 次，实际 \(spy.callCount)")
        XCTAssertEqual(spy.lastRect, rect,
            "ACC-SCREENSHOT-3: captureArea 收到的 rect 必须 == handleConfirm 入参")

        // 硬断言 2：pasteboard 含 PNG，且 == seam 返回的 stubPNG（copyImage 被调，数据不变形）
        let written = pb.data(forType: .png)
        XCTAssertNotNil(written,
            "ACC-SCREENSHOT-3 (mutation-killer): handleConfirm 后 pasteboard 必须含 public.png")
        XCTAssertEqual(written, spy.stubPNG,
            "ACC-SCREENSHOT-3: pasteboard PNG 必须 == captureArea 返回数据，实际 \(written?.count ?? 0) bytes vs stub \(spy.stubPNG.count) bytes")
    }

    /// C-COPY-SEAM: handleConfirm 不触碰系统剪贴板（隔离验证）
    func test_COPY_SEAM_doesNotTouchSystemPasteboard() async throws {
        // 系统剪贴板预埋 sentinel
        let sentinel = "ccb-sentinel-screenshot-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()  // 注入隔离 pb
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        // 系统剪贴板未被改动（注入隔离 CopyService，不污染系统）
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), sentinel,
            "C-COPY-SEAM: handleConfirm 用注入 CopyService 不应触碰系统剪贴板，应仍是 sentinel")
    }
}

// MARK: - ACC-SCREENSHOT-5 / 权限降级：取消与异常路径

@MainActor
final class ScreenshotPluginCancelAndPermissionAcceptanceTests: XCTestCase {

    /// ACC-SCREENSHOT-5: overlay 取消路径不调 captureArea、不写剪贴板
    ///
    /// 本切片 perform 内部完成「确认 → 捕获 → 复制」。取消语义在 overlay 层（ESC），
    /// 测试无法直接驱动 overlay（那是 ScreenshotOverlayController 的职责，见独立 hook 测试）。
    /// 此处断言：若 perform 因某种原因走「取消」分支（如注入取消 flag），seam 不被调。
    ///
    /// CONTRACT_AMBIGUOUS: 若蓝队的 ScreenshotPlugin 注入构造器含取消/确认 seam，
    /// 此处可注入「取消」状态验证。否则标 TODO 留 overlay hook 测试覆盖取消路径。
    func test_ACC5_cancel_doesNotCapture_doesNotCopy() async {
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        // 仅查询候选（不 perform），模拟用户在 overlay 阶段就 ESC 取消
        _ = await plugin.actions(for: "截屏")

        // 取消：seam 未调、pasteboard 空
        XCTAssertEqual(spy.callCount, 0,
            "ACC-SCREENSHOT-5: 仅查询未 perform 时 captureArea 不应被调")
        XCTAssertNil(pb.data(forType: .png),
            "ACC-SCREENSHOT-5: 仅查询未 perform 时 pasteboard 不应被写")
    }

    /// 权限降级：capture seam 抛权限拒绝 → handleConfirm 不崩、不写剪贴板
    ///
    /// ACC-SCREENSHOT-4: 权限未授予时友好降级（不崩、不写剪贴板）
    ///
    /// Mutation-Survival 自检：
    /// - handleConfirm 吞错但仍写 pasteboard mutant → pb 非空 → 本断言失败（捕获）
    /// - handleConfirm 未捕获导致 crash → 测试进程 abort（捕获）
    func test_ACC4_permissionDenied_handleConfirmNoCrash_noCopy() async {
        let deniedCapture = PermissionDeniedCapture()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: deniedCapture, copy: copy)

        // handleConfirm 在权限拒绝 seam 下不 crash（捕获尝试 → 抛错 → 友好降级，不写剪贴板）
        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertNil(pb.data(forType: .png),
            "ACC-SCREENSHOT-4: 权限拒绝时 pasteboard 不应被写（降级不复制）")
    }
}

// MARK: - EnabledStore 开关（对齐 SystemCommand 开关语义）

@MainActor
final class ScreenshotPluginEnabledStoreAcceptanceTests: XCTestCase {

    /// EnabledStore 开关：setEnabled(id:"screenshot", false) → registry 跳过该插件
    func test_ENABLED_disabled_pluginProducesNoCandidates() async {
        // 用隔离 UserDefaults 避免污染其他测试
        let suiteName = "ccb-test-screenshot-enabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = BuiltinPluginEnabledStore(defaults: defaults)
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        let registry = BuiltinPluginRegistry(plugins: [plugin], enabledStore: store)

        // 默认 enabled → 应产出候选
        let enabledResult = await registry.actions(for: "截屏")
        XCTAssertTrue(enabledResult.contains { $0.pluginId == "screenshot" },
            "EnabledStore: 默认 enabled 时 screenshot 必须产出候选")

        // 关闭 → 不产出
        store.setEnabled(id: "screenshot", enabled: false)
        let disabledResult = await registry.actions(for: "截屏")
        XCTAssertFalse(disabledResult.contains { $0.pluginId == "screenshot" },
            "EnabledStore: setEnabled(false) 后 screenshot 不应产出候选（registry 跳过 disabled）")

        // 清理隔离 suite
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// EnabledStore: 关闭后再启用 → 恢复产出（可逆）
    func test_ENABLED_reenable_restoresCandidates() async {
        let suiteName = "ccb-test-screenshot-reenable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = BuiltinPluginEnabledStore(defaults: defaults)
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)
        let registry = BuiltinPluginRegistry(plugins: [plugin], enabledStore: store)

        store.setEnabled(id: "screenshot", enabled: false)
        store.setEnabled(id: "screenshot", enabled: true)

        let result = await registry.actions(for: "截屏")
        XCTAssertTrue(result.contains { $0.pluginId == "screenshot" },
            "EnabledStore: 关闭后再启用必须恢复产出 screenshot 候选")

        defaults.removePersistentDomain(forName: suiteName)
    }

    /// EnabledStore: 与既有插件开关共存（screenshot 开关不影响 system-command）
    func test_ENABLED_screenshotSwitch_doesNotAffect_systemCommand() async {
        let suiteName = "ccb-test-screenshot-isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = BuiltinPluginEnabledStore(defaults: defaults)

        // 关闭 screenshot
        store.setEnabled(id: "screenshot", enabled: false)

        // system-command 仍 enabled（开关独立）
        XCTAssertTrue(store.isEnabled(id: "system-command"),
            "EnabledStore: 关闭 screenshot 不应影响 system-command 的 enabled 状态（开关独立）")

        defaults.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - Tier 1.5 集成：perform → overlay → onConfirm → handleConfirm 全链（SC-2 / SC-3 / SC-5）
//
// 本组是 selective QA 补的「真实场景运行时 artifact」（QA 报告要求 E≥N=6，光代码 review 不够）：
//   - SC-2：perform → present overlay（注入 permissionPreflight={true} 跳 TCC；present 测试模式跳 GUI，断言 isPresented）
//   - SC-3：overlay._simulateConfirm → onConfirm → handleConfirm → captureArea + copyImage（生产全链接线，零 GUI/TCC）
//   - SC-5：overlay._simulateCancel → onCancel → 不捕获不复制
// 配合既有：SC-1（candidate tests）/ SC-4（test_ACC4_permissionDenied_handleConfirmNoCrash_noCopy）/ SC-6（ScreenCapturing.swift:45-53 backingScaleFactor 代码层 + 真机 XCUITest）
//
// 真机 XCUITest 终验（设计 Tier 1.5 真机层，不进 CI）：真实 overlay 视觉呈现 + 真实 SCScreenCapture(@MainActor) 捕获 + TCC 授权流。

@MainActor
final class ScreenshotTier15IntegrationTests: XCTestCase {

    /// SC-2：perform → present overlay（permissionPreflight={true}；present 测试模式跳 GUI）
    func test_SC2_perform_presentsOverlay() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(
            capture: CaptureSpy(), copy: copy, permissionPreflight: { true }
        )
        XCTAssertFalse(plugin.overlayController.isPresented,
            "SC-2 precondition: 未 perform 时 overlay 未 present")

        let actions = await plugin.actions(for: "截屏")
        guard let action = actions.first(where: { $0.pluginId == "screenshot" }) else {
            XCTFail("SC-2 precondition: 必须有 screenshot 候选")
            return
        }
        XCTAssertNoThrow(try action.perform(), "SC-2: perform 不应抛错")

        XCTAssertTrue(plugin.overlayController.isPresented,
            "SC-2 (artifact): perform 后 overlay 必须 present（isPresented==true），实际 \(plugin.overlayController.isPresented)")
    }

    /// SC-2 补充：权限拒绝时 perform 不 present overlay、不捕获（友好降级）
    func test_SC2_permissionDenied_doesNotPresent_noCapture() async {
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy, permissionPreflight: { false }
        )

        let actions = await plugin.actions(for: "截屏")
        guard let action = actions.first(where: { $0.pluginId == "screenshot" }) else {
            XCTFail("precondition"); return
        }
        XCTAssertNoThrow(try action.perform(), "权限拒绝时 perform 不崩")
        XCTAssertFalse(plugin.overlayController.isPresented,
            "SC-2: 权限拒绝时不应 present overlay")
        XCTAssertEqual(spy.callCount, 0, "SC-2: 权限拒绝时不捕获")
    }

    /// SC-3：overlay._simulateConfirm → onConfirm → handleConfirm → captureArea + copyImage（生产全链接线）
    /// 这是 SC-3 真实场景的 CI 等价（程序化 hook 驱动，零 GUI/TCC）；真机 XCUITest 终验完整 overlay 拖框。
    func test_SC3_overlayConfirm_drivesCaptureAndCopy() async throws {
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        // 驱动 overlay 选区 + 确认（plugin 的 onConfirm 已在 init wire 到 handleConfirm）
        plugin.overlayController._simulateDrag(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        _ = try await plugin.overlayController._simulateConfirm()

        // 全链 artifact：overlay.onConfirm → handleConfirm → captureArea → copyImage
        XCTAssertEqual(spy.callCount, 1,
            "SC-3 (artifact): overlay 确认后 captureArea 必须被调 1 次（全链接通），实际 \(spy.callCount)")
        XCTAssertEqual(pb.data(forType: .png), spy.stubPNG,
            "SC-3 (artifact): pasteboard 必须写入 captureArea 返回的 stubPNG")
    }

    /// SC-5：overlay._simulateCancel → onCancel → 不捕获、不复制
    func test_SC5_overlayCancel_noCaptureNoCopy() async {
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        plugin.overlayController._simulateDrag(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        plugin.overlayController._simulateCancel()

        XCTAssertEqual(spy.callCount, 0,
            "SC-5 (artifact): cancel 后 captureArea 不应被调")
        XCTAssertNil(pb.data(forType: .png),
            "SC-5 (artifact): cancel 后 pasteboard 不应被写")
    }
}
