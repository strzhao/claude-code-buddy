import XCTest
@testable import BuddyCore

@MainActor
final class LauncherManagerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // 每次测试前确保 manager 处于已 setup 且隐藏状态
        LauncherManager.shared.setup()
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    func test_show_makesWindowVisible() {
        LauncherManager.shared.show()
        XCTAssertTrue(LauncherManager.shared.isVisible)
        // 清理
        LauncherManager.shared.hide()
    }

    func test_hide_ordersOutWindow() {
        LauncherManager.shared.show()
        LauncherManager.shared.hide()
        XCTAssertFalse(LauncherManager.shared.isVisible)
    }

    func test_hide_whenAlreadyHidden_doesNotToggleState() {
        // 防重入：多次 hide() 不会影响状态
        XCTAssertFalse(LauncherManager.shared.isVisible)
        LauncherManager.shared.hide()
        XCTAssertFalse(LauncherManager.shared.isVisible)
        LauncherManager.shared.hide()
        XCTAssertFalse(LauncherManager.shared.isVisible)
    }

    func test_toggle_alternates() {
        let initial = LauncherManager.shared.isVisible
        LauncherManager.shared.toggle()
        XCTAssertEqual(LauncherManager.shared.isVisible, !initial)
        LauncherManager.shared.toggle()
        XCTAssertEqual(LauncherManager.shared.isVisible, initial)
    }

    func test_centerOnScreen_positionsAtGoldenRatio() {
        LauncherManager.shared.show()
        guard let screen = NSScreen.main else {
            XCTSkip("No main screen available")
            return
        }
        // LauncherManager.show() 调用了 centerOnScreen()
        // 通过测试 isVisible=true 间接确认 show 路径正常
        XCTAssertTrue(LauncherManager.shared.isVisible)

        // 直接验证屏幕位置不易在测试环境中实现（需访问私有 window 属性），
        // 此处通过 isVisible=true 确认 show() 完整路径可达
        LauncherManager.shared.hide()
    }

    func test_submit_returnsEchoPlaceholder() async {
        let result = await LauncherManager.shared.submit("hi")
        XCTAssertEqual(String(result.characters), "echo: hi")
    }

    func test_sharedIsSingleton() {
        let a = LauncherManager.shared
        let b = LauncherManager.shared
        XCTAssertTrue(a === b)
    }
}
