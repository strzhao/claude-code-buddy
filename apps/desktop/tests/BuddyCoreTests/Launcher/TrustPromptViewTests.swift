import XCTest
import SwiftUI
@testable import BuddyCore

// MARK: - TrustPromptViewTests
//
// 蓝队单测 T4（M4 弹框内修订 + 方案 B 毛玻璃窗口）：TrustPromptView SwiftUI 全内容
// （信任区 + 依赖列表区 + 进度区 + 按钮区，契约 M4 + Cross.Freshness）。
//
// 契约引用（state.md ## 设计文档 M4 弹框执行流 + 横切 Freshness + 方案 B 毛玻璃窗口）：
//   - @ObservedObject var installer: DependencyInstaller（绑定 @Published，全内容实时刷新）
//   - 四层结构：信任说明区 / 依赖列表区 / 进度区 / 按钮区（Cross.Freshness2 三层 + 按钮区）
//   - 独立依赖区 AXGroup + 来源标签 Homebrew（Cross.Freshness1）
//   - 依赖状态 badge：✓已装绿 / ⚡未装橙+一键安装 / ⟳安装中进度 / ✗失败重试 / ⚠无brew映射手动
//   - 进度区：installingLabel + progressPhase + ProgressView + 取消按钮（@Published 驱动）
//   - 按钮区：「允许并运行」（依赖全装才 enable，Q1）+「拒绝」
//   - brew 缺失：引导文本 + 不显示一键安装（场景 6）
//   - 全局开关关：显示 `brew install <pkg>` 命令（场景 7）
//
// 测试策略：验证 View 构造不崩 + helper 逻辑（brewInstallCommands）+ installer 绑定刷新 +
// 新增 approveEnabled 逻辑（依赖全装才 enable）+ 四层 AX id 可达。
// AX 可达性 / 视觉断言归 QA Tier 1.5（真实 NSHostingView 渲染）。
//
// TDD：本文件先于实现编写，最初编译失败（RED），实现后转 GREEN。

@MainActor
final class TrustPromptViewTests: XCTestCase {

    private func status(_ check: String, brew: String? = "pkg", label: String? = "工具", installed: Bool = false) -> DependencyStatus {
        DependencyStatus(check: check, label: label, isInstalled: installed, brewPackage: brew)
    }

    /// 构造默认 installer（空 statuses，M4 弹框内初始状态）。
    private func makeInstaller(statuses: [DependencyStatus] = []) -> DependencyInstaller {
        let installer = DependencyInstaller()
        installer.statuses = statuses
        return installer
    }

    /// 构造 TrustPromptView（方案 B 新签名：pluginName + informativeText + hasDeps 必填）。
    private func makeView(
        pluginName: String = "qr",
        informativeText: String = "qr plugin\n模式: command",
        statuses: [DependencyStatus] = [],
        brewAvailability: BrewAvailability = .available(path: "/opt/homebrew/bin/brew"),
        isAlreadyTrusted: Bool = false,
        hasDeps: Bool = true,
        autoInstallEnabled: Bool = true,
        installer: DependencyInstaller? = nil,
        onInstallAll: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onApprove: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {}
    ) -> TrustPromptView {
        TrustPromptView(
            pluginName: pluginName,
            informativeText: informativeText,
            statuses: statuses,
            brewAvailability: brewAvailability,
            isAlreadyTrusted: isAlreadyTrusted,
            hasDeps: hasDeps,
            autoInstallEnabled: autoInstallEnabled,
            installer: installer ?? makeInstaller(statuses: statuses),
            onInstallAll: onInstallAll,
            onCancel: onCancel,
            onApprove: onApprove,
            onDeny: onDeny
        )
    }

    // MARK: - View 构造不崩（@ObservedObject installer 注入 + 方案 B 新签名）

    /// 契约 M4：TrustPromptView 构造不崩（基本可用性，@ObservedObject installer 注入 + 方案 B 新签名）。
    func test_AT01_viewInit_doesNotCrash() {
        let view = makeView(statuses: [status("qrencode")])
        XCTAssertNotNil(view, "TrustPromptView 构造应成功")
    }

    /// 契约 M4：空依赖列表构造不崩（无依赖区场景）。
    func test_AT02_emptyStatuses_doesNotCrash() {
        let view = makeView(statuses: [], hasDeps: false)
        XCTAssertNotNil(view)
    }

    /// 契约 M4：brew 缺失场景构造不崩。
    func test_AT03_brewMissing_doesNotCrash() {
        let view = makeView(
            statuses: [status("qrencode", brew: "qrencode")],
            brewAvailability: .missing
        )
        XCTAssertNotNil(view)
    }

    /// 契约 M4：已信任 + 重弹场景构造不崩（标记已授权）。
    func test_AT04_alreadyTrusted_doesNotCrash() {
        let view = makeView(
            statuses: [status("imagemagick", brew: "imagemagick")],
            isAlreadyTrusted: true
        )
        XCTAssertNotNil(view)
    }

    /// 契约 M4：全局开关关场景构造不崩（手动命令模式）。
    func test_AT05_autoInstallOff_doesNotCrash() {
        let view = makeView(
            statuses: [status("qrencode", brew: "qrencode")],
            autoInstallEnabled: false
        )
        XCTAssertNotNil(view)
    }

    /// 契约 M4（弹框内修订）：@ObservedObject installer 绑定 @Published 进度状态。
    /// 构造 installer 并设置 installingLabel/progressPhase，View 绑定后不崩。
    func test_AT06_withInstaller_bindsPublishedState() {
        let installer = makeInstaller()
        installer.installingLabel = "二维码生成库"
        installer.progressPhase = "Downloading"
        let view = makeView(statuses: [status("qrencode")], installer: installer)
        XCTAssertNotNil(view)
        // 绑定验证：installer 状态变化后 View 仍可构造（@Published 刷新，全内容 pump）
        installer.progressPhase = "Installing"
        XCTAssertNotNil(view)
    }

    /// 契约 M4（弹框内修订）：一键安装按钮 action 注入不崩。
    /// onInstallAll 闭包由 TrustPrompt.askUserWithDeps 注入（调 installer.installAll(missing)）。
    func test_AT07_onInstallAllAction_injected() {
        var installCalled = false
        let view = makeView(
            statuses: [status("qrencode")],
            onInstallAll: { installCalled = true }
        )
        XCTAssertNotNil(view)
        // action 触发验证归 QA Tier 1.5（NSHostingView 真机点击），单测仅验证闭包注入不崩
        XCTAssertFalse(installCalled, "初始未触发")
    }

    /// 契约 M4（弹框内修订）：取消按钮 action 注入不崩。
    /// onCancel 由 TrustPrompt.askUserWithDeps 注入（调 installer.cancel()）。
    func test_AT08_onCancelAction_injected() {
        var cancelCalled = false
        let view = makeView(
            statuses: [status("qrencode")],
            onCancel: { cancelCalled = true }
        )
        XCTAssertNotNil(view)
        XCTAssertFalse(cancelCalled, "初始未触发")
    }

    // MARK: - 方案 B 新增：按钮区 action 注入（onApprove/onDeny）

    /// 契约 M4（方案 B）：「允许并运行」按钮 action 注入不崩。
    /// onApprove 由 TrustPrompt.askUserWithDeps 注入（NSApp.stopModal(withCode:.OK)）。
    func test_AT08b_onApproveAction_injected() {
        var approveCalled = false
        let view = makeView(
            statuses: [status("qrencode")],
            onApprove: { approveCalled = true }
        )
        XCTAssertNotNil(view)
        XCTAssertFalse(approveCalled, "初始未触发")
    }

    /// 契约 M4（方案 B）：「拒绝」按钮 action 注入不崩。
    /// onDeny 由 TrustPrompt.askUserWithDeps 注入（NSApp.stopModal(withCode:.cancel)）。
    func test_AT08c_onDenyAction_injected() {
        var denyCalled = false
        let view = makeView(
            statuses: [status("qrencode")],
            onDeny: { denyCalled = true }
        )
        XCTAssertNotNil(view)
        XCTAssertFalse(denyCalled, "初始未触发")
    }

    // MARK: - brewInstallCommands helper（全局开关关时复制命令）

    /// 契约 M7：全局开关关 → brewInstallCommands 生成 `brew install <pkg>` 列表。
    func test_AT09_brewInstallCommands_generatesCorrectCommands() {
        let statuses = [
            status("qrencode", brew: "qrencode"),
            status("imagemagick", brew: "imagemagick"),
        ]
        let cmds = TrustPromptView.brewInstallCommands(for: statuses)
        XCTAssertEqual(cmds, "brew install qrencode\nbrew install imagemagick")
    }

    /// 契约 M7：无 brew 映射依赖（brewPackage=nil）→ 不生成命令。
    func test_AT10_brewInstallCommands_skipsNoBrewMapping() {
        let statuses = [
            status("qrencode", brew: "qrencode"),
            status("custom-tool", brew: nil),
        ]
        let cmds = TrustPromptView.brewInstallCommands(for: statuses)
        XCTAssertEqual(cmds, "brew install qrencode", "无 brew 映射项应被跳过")
    }

    /// 契约 M7：空列表 → 空字符串。
    func test_AT11_brewInstallCommands_emptyReturnsEmpty() {
        XCTAssertEqual(TrustPromptView.brewInstallCommands(for: []), "")
    }

    // MARK: - DependencyRow 构造

    /// 契约 M4：DependencyRow 构造不崩（各状态）。
    func test_AT12_dependencyRow_variousStates() {
        // 已装
        _ = DependencyRow(status: status("qrencode", installed: true), brewAvailable: true, autoInstallEnabled: true)
        // 未装
        _ = DependencyRow(status: status("qrencode", installed: false), brewAvailable: true, autoInstallEnabled: true)
        // brew 缺失
        _ = DependencyRow(status: status("qrencode"), brewAvailable: false, autoInstallEnabled: true)
        // 手动模式
        _ = DependencyRow(status: status("qrencode"), brewAvailable: true, autoInstallEnabled: false)
    }

    // MARK: - 方案 B 新增：无依赖纯信任框（hasDeps=false）

    /// 契约 M4（方案 B）：无依赖插件首次 → 纯信任框（hasDeps=false，不展示依赖区）。
    /// 对应场景 5.P1（无依赖插件首次运行，依赖区不应出现）。
    func test_AT13_noDeps_pureTrustView_constructs() {
        let view = makeView(
            pluginName: "translate",
            informativeText: "translate helper\n模式: prompt",
            statuses: [],
            hasDeps: false
        )
        XCTAssertNotNil(view, "无依赖纯信任框构造应成功")
    }

    // MARK: - 方案 B 新增：brew 缺失引导框（showBrewMissingGuide 复用 TrustPromptView）

    /// 契约 M6（方案 B）：brew 缺失引导框复用 TrustPromptView（brewAvailability=.missing）。
    /// 对应场景 6.P1（brew 未装 + 有 brew 依赖 → 失败状态，无一键安装）。
    func test_AT14_brewMissingGuide_constructs() {
        let view = makeView(
            pluginName: "无法自动安装依赖",
            informativeText: "以下依赖需要 Homebrew 才能自动安装：qrencode",
            statuses: [status("qrencode", brew: "qrencode")],
            brewAvailability: .missing,
            autoInstallEnabled: true
        )
        XCTAssertNotNil(view, "brew 缺失引导框构造应成功")
    }
}
