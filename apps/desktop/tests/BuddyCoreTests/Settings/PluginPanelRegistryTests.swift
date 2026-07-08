import XCTest
import AppKit
@testable import BuddyCore

// MARK: - PluginPanelRegistryTests
//
// 蓝队单测：PluginPanelRegistry 注册表 + 空态路由（T1）。
//
// 契约引用（state.md ## 契约规约 C3 + 验收场景 AC-SNIPGUI-03/27）：
//   - 注册表空 → 所有插件走 EmptyPluginStateVC 不崩
//   - 命中 provider → 返回其 makePanelVC()；未命中 → nil（调用方走空态）
//
@MainActor
final class PluginPanelRegistryTests: XCTestCase {

    override func tearDown() async throws {
        // 重置注册表（避免跨测试污染）
        PluginPanelRegistry.shared.resetForTesting()
        try await super.tearDown()
    }

    // AC-SNIPGUI-27：注册表空 → provider 返回 nil
    func test_emptyRegistry_providerReturnsNil() {
        PluginPanelRegistry.shared.resetForTesting()
        XCTAssertNil(PluginPanelRegistry.shared.provider(for: "snip"))
        XCTAssertNil(PluginPanelRegistry.shared.provider(for: "calculator"))
    }

    // 命中 → 返回注册的 provider
    func test_registeredProvider_returnsProvider() {
        let stub = StubPanelProvider()
        PluginPanelRegistry.shared.register(stub, for: "snip")
        XCTAssertNotNil(PluginPanelRegistry.shared.provider(for: "snip"))
    }

    // 未命中（其他插件名）→ nil
    func test_otherPlugin_returnsNil() {
        let stub = StubPanelProvider()
        PluginPanelRegistry.shared.register(stub, for: "snip")
        XCTAssertNil(PluginPanelRegistry.shared.provider(for: "calculator"))
    }

    // makePanelVC 每次返回新实例
    func test_makePanelVC_returnsFreshInstance() {
        let stub = StubPanelProvider()
        let a = stub.makePanelVC()
        let b = stub.makePanelVC()
        XCTAssertFalse(a === b, "makePanelVC 应每次返回新实例")
    }

    // AC-SNIPGUI-03：EmptyPluginStateVC 渲染含「无可配置」文本
    func test_emptyPluginStateVC_containsNoConfigText() {
        let vc = EmptyPluginStateVC(
            name: "calculator",
            summary: "数学计算",
            description: "输入算式即时出结果",
            enabled: true
        )
        vc.loadView()
        // 找 AX identifier 为 empty_plugin.title 的 view
        let titleView = findView(byID: "empty_plugin.title", in: vc.view)
        XCTAssertNotNil(titleView, "应含 empty_plugin.title AX identifier")
        if let label = titleView as? NSTextField {
            XCTAssertTrue(label.stringValue.contains("无可配置"), "空态 VC 应含「无可配置」文本（AC-SNIPGUI-03）")
        }
    }

    // MARK: - Helpers

    private func findView(byID id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for sub in root.subviews {
            if let found = findView(byID: id, in: sub) { return found }
        }
        return nil
    }
}

// MARK: - StubPanelProvider（测试专用）

private final class StubPanelProvider: PluginSettingsPanelProvider {
    func makePanelVC() -> NSViewController {
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        return vc
    }
}
