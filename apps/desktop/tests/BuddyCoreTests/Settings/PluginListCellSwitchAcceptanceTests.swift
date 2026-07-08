import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：插件设置页左栏开关可点 + 点击贯通插件启用状态翻转

/// 红队独立编写，基于设计文档契约 + 验收场景 AS-01/02/03（SSOT）。
/// 严格黑盒视角：断言"设计应达到的状态"，期望值字面量取自 assert:。
///
/// 覆盖契约：
/// - C-SWITCH-SIZE：PluginListCellView 的 SageSwitch 显式 width=32 + height=20
/// - C-SWITCH-INTRINSIC：SageSwitch.intrinsicContentSize == (32, 20)
/// - C-SWITCH-CLICK-PATH：mouseDown → toggle → onChange → cell.onToggle → togglePlugin（禁 test hook）
/// - C-NO-REGRESSION：本测试不动 SettingsToggleRow；AT10/AT11 旧测试留原文件守护
///
/// Mutation-Survival 自检（反 no-op）：
/// - AS-02：断言 captured == true（非 nil）。mouseDown 空实现 / 未接 onChange 时 captured 保持 nil → fail。
/// - AS-03：断言 store.isEnabled 翻转。mouseDown 未接通 togglePlugin 时 store 不变 → fail。
@MainActor
final class PluginListCellSwitchAcceptanceTests: XCTestCase {

    /// calculator 内置插件 id（契约字面量）。
    private static let calculatorId = "calculator"

    /// BuiltinPluginEnabledStore 的 disabled key（用于测试隔离清理）。
    private static func disabledKey(_ id: String) -> String {
        "\(BuiltinPluginEnabledStore.keyPrefix)\(id)\(BuiltinPluginEnabledStore.disabledSuffix)"
    }

    override func setUp() {
        super.setUp()
        // 隔离：确保 calculator 开关回到默认 enabled（无 key = true）
        UserDefaults.standard.removeObject(forKey: Self.disabledKey(Self.calculatorId))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.disabledKey(Self.calculatorId))
        super.tearDown()
    }

    // MARK: - Helpers

    /// 在 cell 的 subview 树中查找 SageSwitch（不依赖 internal access level，最稳）。
    private func findSageSwitch(in cell: NSView) -> SageSwitch? {
        if let s = cell as? SageSwitch { return s }
        for sub in cell.subviews {
            if let found = findSageSwitch(in: sub) { return found }
        }
        return nil
    }

    /// 在 vc.view 树中查找 NSTableView（sidebarTableView 是 private，靠类型查找）。
    private func findTableView(in view: NSView) -> NSTableView? {
        if let tv = view as? NSTableView { return tv }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }

    /// 构造一个 leftMouseDown NSEvent（in-process 直接喂给 mouseDown，无需真事件路由）。
    private func makeMouseDownEvent(in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    /// 把 cell 放进临时 NSWindow 触发完整 Auto Layout 解析。
    /// 光 init 不 layout 时 frame 是 init 值或 .zero；必须放进窗口 + layoutSubtreeIfNeeded。
    private func mountInWindowForLayout(_ cell: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView()
        window.contentView?.addSubview(cell)
        // 给 cell 一个明确 frame，让其内部约束可解析（约束相对 cell 边界）
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        window.layoutIfNeeded()
        cell.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - AS-01: SageSwitch 在 cell 中有正确尺寸 32×20（C-SWITCH-SIZE）

    /// [det-machine] AS-01：实例化 PluginListCellView，configure(name:"x",isOn:false)，
    /// 放入窗口触发 layout；observe: 开关 frame；assert: width == 32 && height == 20
    ///
    /// Kill no-op：若开关缺尺寸约束（root cause），Auto Layout 解析 frame 为 0×0 → fail。
    func test_AS01_sageSwitch_hasExplicitSize32x20() {
        let cell = PluginListCellView()
        cell.configure(name: "x", summary: "", sourceBadge: "", isOn: false)

        guard let switchView = findSageSwitch(in: cell) else {
            return XCTFail("PluginListCellView 的 subview 树中应含 SageSwitch（C-SWITCH-CLICK-PATH 组件存在）")
        }

        // 触发完整 Auto Layout（光 init 不 layout，frame 是 init 值或 .zero）
        _ = mountInWindowForLayout(cell)

        let frame = switchView.frame
        XCTAssertEqual(frame.width, 32, accuracy: 0.001,
                       "C-SWITCH-SIZE: SageSwitch.width 必须 == 32（实际 \(frame.width)，0×0 = 未加约束 = root cause 未修）")
        XCTAssertEqual(frame.height, 20, accuracy: 0.001,
                       "C-SWITCH-SIZE: SageSwitch.height 必须 == 20（实际 \(frame.height)）")
    }

    // MARK: - AS-01b: SageSwitch 组件级 intrinsicContentSize 契约（C-SWITCH-INTRINSIC）

    /// C-SWITCH-INTRINSIC：SageSwitch.intrinsicContentSize == NSSize(width: 32, height: 20)
    /// 这是组件级尺寸契约，独立于 cell 约束。任何使用 SageSwitch 的宿主都能靠 intrinsicContentSize 撑开。
    func test_AS01b_sageSwitch_intrinsicContentSize_is32x20() {
        let switchView = SageSwitch(isOn: false)
        let size = switchView.intrinsicContentSize
        XCTAssertEqual(size.width, 32, accuracy: 0.001,
                       "C-SWITCH-INTRINSIC: SageSwitch.intrinsicContentSize.width == 32（实际 \(size.width)）")
        XCTAssertEqual(size.height, 20, accuracy: 0.001,
                       "C-SWITCH-INTRINSIC: SageSwitch.intrinsicContentSize.height == 20（实际 \(size.height)）")
    }

    // MARK: - AS-02: 点击链路 mouseDown → toggle → onChange → cell.onToggle（C-SWITCH-CLICK-PATH）

    /// [det-machine] AS-02：同 AS-01 cell，注册 cell.onToggle={captured=$0}，
    /// 触发开关 mouseDown(with: NSEvent)；observe: captured；assert: captured == true
    ///
    /// Kill no-op（关键 mutation 自检）：
    /// - 若 SageSwitch.mouseDown 是空实现（{}），toggle() 不执行，onChange 不调，captured 保持 nil → fail。
    /// - 若 cell.onToggle setter 未接通 toggleSwitch.onChange，mouseDown 走通但 captured 仍 nil → fail。
    /// 断言 captured == true（非 nil，非 Optional.some 判空），强保证点击链路贯通。
    func test_AS02_clickPath_mouseDownFlipsCapturedToggle() {
        let cell = PluginListCellView()
        cell.configure(name: "x", summary: "", sourceBadge: "", isOn: false)

        guard let switchView = findSageSwitch(in: cell) else {
            return XCTFail("PluginListCellView 的 subview 树中应含 SageSwitch")
        }

        // 注册 cell.onToggle 回调，捕获翻转后的状态
        var captured: Bool?
        cell.onToggle = { isOn in captured = isOn }

        // 触发真实点击链路（in-process 直接调 mouseDown，不绕 toggleButtonClicked test hook）
        // 初始 isOn=false → mouseDown → toggle → isOn=true → onChange(true) → cell.onToggle(true)
        let event = makeMouseDownEvent(in: switchView)
        switchView.mouseDown(with: event)

        XCTAssertNotNil(captured,
                        "AS-02 kill no-op: mouseDown 必须触发 onChange→cell.onToggle，captured 不应为 nil（mouseDown 空实现 / onChange 未接通 → fail）")
        XCTAssertEqual(captured, true,
                       "AS-02: 初始 isOn=false，点击后 captured 必须翻转为 true（实际 \(String(describing: captured))）")
        // 额外强断言开关自身状态翻转（kill「onChange 调了但 toggle 没翻」mutation）
        XCTAssertTrue(switchView.isOn,
                      "AS-02: mouseDown 后 SageSwitch.isOn 必须翻转为 true（kill toggle no-op）")
    }

    // MARK: - AS-03: 端到端 mouseDown → store.isEnabled 翻转（calculator builtin）

    /// [det-machine] AS-03：PluginGalleryViewController 装载含一个 builtin（calculator）的 registry，
    /// 选中该插件行，触发其 cell 的 SageSwitch mouseDown；
    /// observe: builtinEnabledStore.isEnabled(id:"calculator")；
    /// assert: 点击后与初始值相反（端到端：点击 → store 持久化翻转）
    ///
    /// Kill no-op（关键 mutation 自检）：
    /// - 若 cell.onToggle 未接通 vc.togglePlugin（如 cell.onToggle 被覆盖 / closure 丢失 weak self），
    ///   store.isEnabled 不变 → 与初始值相同 → fail。
    /// - 端到端覆盖完整链路：mouseDown → toggle → onChange → cell.onToggle → vc.togglePlugin → store.setEnabled。
    func test_AS03_endToEnd_mouseDownFlipsCalculatorStoreEnabled() async {
        // 准备：calculator 初始 enabled=true（默认无 key = true）
        let registry = BuiltinPluginRegistry(plugins: [CalculatorPlugin()])
        let store = BuiltinPluginEnabledStore.shared
        let initialEnabled = store.isEnabled(id: Self.calculatorId)
        XCTAssertTrue(initialEnabled,
                      "AS-03 前置：calculator 初始应 enabled（默认 true），实际 \(initialEnabled)")

        // 装载 VC：注入含 calculator 的 registry，触发 loadView + refresh
        let vc = PluginGalleryViewController(
            marketplace: RedEmptyMarketplaceInspecting(),
            plugins: RedNoopPluginToggling(),
            builtinRegistry: registry,
            builtinEnabledStore: store
        )
        // force loadView（建 tableView）
        _ = vc.view
        // 触发 viewDidAppear 让 refresh 跑完（normal 态含 settingsEntry + calculator 两个 entry）
        vc.viewDidAppear()
        // 等 refresh 的 Task 串行
        await Task.yield()
        await Task.yield()
        await Task.yield()

        // 定位 tableView + calculator 行
        guard let tableView = findTableView(in: vc.view) else {
            return XCTFail("PluginGalleryViewController.view 树中应含 NSTableView（sidebar 列表）")
        }

        // calculator entry 在 row 1（row 0 是 settingsEntry 虚拟项）
        // 先断言 state normal 且含 calculator，避免行号漂移误判
        guard case .normal(let entries) = vc.state else {
            return XCTFail("AS-03: refresh 后 state 应为 .normal，实际 \(vc.state)")
        }
        let calculatorRow = entries.firstIndex(where: { $0.name == Self.calculatorId && $0.source == "builtin" })
        guard let row = calculatorRow else {
            return XCTFail("AS-03: state.normal 应含 source=builtin name=calculator entry，实际 entries: \(entries.map { "(\($0.source):\($0.name))" })")
        }

        // 取该行 cell（makeIfNecessary 让 delegate 填 cell + 接 onToggle）
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? PluginListCellView else {
            return XCTFail("AS-03: row \(row) 的 cell 应为 PluginListCellView")
        }

        guard let switchView = findSageSwitch(in: cell) else {
            return XCTFail("AS-03: cell 的 subview 树中应含 SageSwitch")
        }

        // 端到端触发：真实 mouseDown（不走 toggleButtonClicked test hook）
        // 初始 calculator enabled=true → 点击 → togglePlugin(enable:false) → store.setEnabled(id:calculator, enabled:false)
        let event = makeMouseDownEvent(in: switchView)
        switchView.mouseDown(with: event)

        // togglePlugin 对 builtin 同步调 store.setEnabled（不进 Task），可直接断言
        // （refresh 是 Task，但 store 写入在 togglePlugin 同步段）
        let afterEnabled = store.isEnabled(id: Self.calculatorId)
        XCTAssertNotEqual(afterEnabled, initialEnabled,
                          "AS-03 kill no-op: 点击后 store.isEnabled(calculator) 必须与初始值 \(initialEnabled) 相反（实际 \(afterEnabled)）。" +
                          "若相等 = cell.onToggle 未接通 vc.togglePlugin / store.setEnabled 未调用 → fail")
        XCTAssertEqual(afterEnabled, false,
                       "AS-03: 初始 enabled=true，点击后必须翻转为 false（实际 \(afterEnabled)）")
    }
}

// MARK: - 红队独立 mock（不复用蓝队 mock，避免耦合）

/// 空 marketplace（无 plugins/sideloaded），让 PluginGallery 只渲染 builtin entries。
private final class RedEmptyMarketplaceInspecting: MarketplaceInspecting {
    func inspect() throws -> MarketplaceInspection {
        MarketplaceInspection(
            plugins: [],
            sideloadedPlugins: [],
            lastSyncedAt: nil,
            consecutiveSyncFailures: 0
        )
    }
    func reseed() async throws {}
}

/// no-op PluginToggling（builtin 路径不走它，仅满足 init DI）。
private final class RedNoopPluginToggling: PluginToggling {
    func disable(name: String) throws {}
    func enable(name: String) throws {}
}
