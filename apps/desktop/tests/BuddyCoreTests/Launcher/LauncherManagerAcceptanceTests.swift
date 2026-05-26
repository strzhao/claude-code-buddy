import XCTest
import AppKit
import Combine
@testable import BuddyCore

// MARK: - LauncherManagerAcceptanceTests
//
// 验收测试：LauncherManager show / hide / toggle / submit 状态契约
//
// 设计文档覆盖点（SC-01 / SC-08）：
//   A. show() 后 isVisible == true
//   B. hide() 后 isVisible == false
//   C. toggle() 状态翻转正确（idle → visible → idle）
//   D. 连续 hide() 幂等（防重入 guard isVisible 验证）
//   E. submit("test") 返回 AttributedString("echo: test")（SC-08 echo 占位）
//   F. submit 每次调用独立计算，无内部 messages 数组持久化
//   G. LauncherManager.shared 单例（同一对象引用）
//   H. app 启动后 setup() 被调用的集成场景
//
// 黑盒原则：通过 LauncherManager 公开 API 和 isVisible 属性观察行为。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherManagerAcceptanceTests: XCTestCase {

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // 确保每个测试开始时 launcher 处于隐藏状态，避免测试间相互干扰
        LauncherManager.shared.hide()
    }

    override func tearDown() async throws {
        LauncherManager.shared.hide()
        try await super.tearDown()
    }

    // MARK: - A. show() 后 isVisible == true（SC-01）

    /// show() 之后 isVisible 必须翻转为 true。
    /// Mutation 探针：如果 show() 是 no-op，isVisible 保持 false → 测试红灯。
    func test_SC01_show_setsIsVisibleTrue() {
        // Given: manager 处于隐藏状态
        LauncherManager.shared.hide()
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "Precondition: isVisible should be false before show()")

        // When
        LauncherManager.shared.show()

        // Then: 必须是精确值断言，不能只是 "窗口可见"
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "isVisible must be true after show()")
    }

    // MARK: - B. hide() 后 isVisible == false（SC-01）

    /// hide() 之后 isVisible 必须翻转为 false。
    func test_SC01_hide_setsIsVisibleFalse() {
        // Given: manager 先 show
        LauncherManager.shared.show()
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "Precondition: isVisible should be true after show()")

        // When
        LauncherManager.shared.hide()

        // Then
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "isVisible must be false after hide()")
    }

    // MARK: - C. toggle() 状态翻转（SC-01）

    /// toggle() 从 false → true → false，精确断言每步状态值。
    func test_SC01_toggle_alternatesIsVisible() {
        // Given: 初始隐藏
        LauncherManager.shared.hide()
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "Precondition: should start hidden")

        // When: 第一次 toggle
        LauncherManager.shared.toggle()

        // Then: 变为可见
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "First toggle() must make isVisible == true")

        // When: 第二次 toggle
        LauncherManager.shared.toggle()

        // Then: 变回隐藏
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "Second toggle() must make isVisible == false")

        // When: 第三次 toggle（再次验证幂等性循环）
        LauncherManager.shared.toggle()
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "Third toggle() must make isVisible == true again")
    }

    // MARK: - D. 连续 hide() 幂等（防重入 guard 验证）（SC-01）

    /// 连续两次 hide() 后 isVisible 仍然 == false。
    /// 验证 hide() 内部的 `guard isVisible else { return }` 防重入保护。
    /// Mutation 探针：如果移除 guard，第二次 hide() 可能导致状态异常或崩溃。
    func test_SC01_consecutiveHide_isIdempotent() {
        // Given: 先 show
        LauncherManager.shared.show()
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "Precondition: should be visible")

        // When: 连续两次 hide()
        LauncherManager.shared.hide()
        LauncherManager.shared.hide()  // 第二次必须安全（不崩溃、不改变状态）

        // Then: 状态仍然是 false（防重入 guard 正确工作）
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "isVisible must remain false after two consecutive hide() calls")
    }

    /// hide() 在已隐藏状态下调用不崩溃，isVisible 保持 false。
    func test_SC01_hideWhenAlreadyHidden_doesNotCrash() {
        // Given: 初始已隐藏
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "Precondition: should start hidden")

        // When: 在已隐藏状态下调用 hide()（不应崩溃）
        XCTAssertNoThrow(LauncherManager.shared.hide(),
                         "hide() on already-hidden manager must not throw or crash")

        // Then
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "isVisible must remain false")
    }

    // MARK: - E. submit("test") 返回 echo 占位（SC-08）

    // MARK: - F. SC-08 契约演进说明（task 001 → task 002）
    //
    // task 001 红队最初锁定 `submit("hi") → "echo: hi"` 的 echo 占位行为。
    // task 002 brief 明确**重写 submit** 接入 ProviderFactory.create → provider.send。
    // 因此 echo 行为只是 task 001 阶段的过渡占位，并非长期契约。
    //
    // 本次 task 002 实现后：
    //   - 未配置 provider → submit 返回 providerNotConfigured 错误（验证见 LauncherManagerTests
    //     的 test_submit_whenNotConfigured_returnsProviderNotConfiguredError）
    //   - 已配置 provider → 走 provider.send 真实请求
    //
    // SC-08 的"每次唤起为独立新 session"语义在 task 002 仍成立（无内部 messages 累积），
    // 但断言形态从"echo 字符串匹配"变为"无状态调用"，由 task 003 agent loop 接管完整验证。

    /// 连续两次 submit 独立计算（SC-08 — 无内部 messages 累积）
    /// task 002 契约演进：错误消息本身也是无状态的，第二次调用不会包含第一次的输入。
    func test_SC08_submit_isStateless_noPersistentMessages() async {
        // Given: 无 provider 配置（每次 submit 走相同的错误路径）
        let first = await LauncherManager.shared.submit("first-message")
        let second = await LauncherManager.shared.submit("second-message")

        // Then: 两次结果应一致（都是 providerNotConfigured 错误），不携带任何前序输入
        let firstStr = String(first.characters)
        let secondStr = String(second.characters)
        XCTAssertEqual(firstStr, secondStr,
                       "无 provider 时连续调用应返回完全相同错误（无状态）")
        XCTAssertFalse(secondStr.contains("first-message"),
                       "第二次结果不应含第一次 query 内容（防 messages 数组累积）")
        XCTAssertFalse(firstStr.contains("second-message"),
                       "第一次结果不应含第二次 query 内容（防引用未来状态）")
    }

    // MARK: - G. LauncherManager.shared 单例

    /// LauncherManager.shared 必须是同一对象引用（单例语义）。
    func test_shared_isSingleton() {
        let ref1 = LauncherManager.shared
        let ref2 = LauncherManager.shared
        XCTAssertTrue(ref1 === ref2,
                      "LauncherManager.shared must return the same instance (singleton)")
    }

    // MARK: - H. 集成：setup() 被调用后 LauncherManager 进入就绪状态

    /// 模拟"app 启动后 LauncherManager.setup() 被调用"的集成场景。
    /// setup() 完成后，manager 应处于 isVisible == false（未展示）的就绪状态，
    /// 随后 show() 能正确翻转 isVisible。
    func test_integration_setupThenShow_managerBecomesVisible() {
        // When: 模拟 AppDelegate.applicationDidFinishLaunching 调用 setup()
        LauncherManager.shared.setup()

        // Then: setup() 不应自动显示窗口
        XCTAssertFalse(LauncherManager.shared.isVisible,
                       "setup() must not auto-show the launcher window")

        // When: 用户触发 show()（模拟快捷键回调）
        LauncherManager.shared.show()

        // Then: isVisible 翻转为 true
        XCTAssertTrue(LauncherManager.shared.isVisible,
                      "show() after setup() must set isVisible = true")

        // Cleanup
        LauncherManager.shared.hide()
    }

    // MARK: - isVisible @Published — Combine 订阅可收到变更

    /// isVisible 是 @Published，show() 触发的变更必须通过 Combine 可观察到。
    func test_SC01_isVisible_isPublished_changeNotified() {
        var receivedValues: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        // Given: 订阅 isVisible 变更（跳过初始值，只关注后续变化）
        LauncherManager.shared.$isVisible
            .dropFirst()
            .sink { receivedValues.append($0) }
            .store(in: &cancellables)

        // When
        LauncherManager.shared.hide()   // false → false（guard 防重入，不发布）
        LauncherManager.shared.show()   // false → true
        LauncherManager.shared.hide()   // true → false

        // Then: 应收到恰好 2 次变更（show 和 hide 各一次，hide→hide 被防重入 guard 过滤）
        XCTAssertEqual(receivedValues.count, 2,
                       "isVisible should publish exactly 2 changes: show() then hide()")
        XCTAssertEqual(receivedValues[0], true,  "First published value should be true (show)")
        XCTAssertEqual(receivedValues[1], false, "Second published value should be false (hide)")
    }
}
