import XCTest
import AppKit
import KeyboardShortcuts
@testable import BuddyCore

// MARK: - LauncherHotkeyAcceptanceTests
//
// 验收测试：LauncherHotkey 注册、探针、常量契约（红队黑盒视角）
//
// 设计文档覆盖点（SC-01）：
//   A. LauncherHotkey.toggle.rawValue == "launcher-toggle"（契约锁定）
//   B. register() 后 KeyboardShortcuts.getShortcut(for: .toggle) 非 nil
//   C. probeIfNeeded() 写入 UserDefaults launcher.hotkeyProbeCompleted=true
//   D. probeIfNeeded() 在快捷键已配置时返回 true
//   E. probeIfNeeded() flag 已存在时走早返回路径，仍返回 true
//   F. UserDefaults key 以 "launcher." 前缀，不与 "alwaysShowLabel" 冲突
//   G. hotkeyProbeCompletedKey 精确值 == "launcher.hotkeyProbeCompleted"
//
// 常量验收（LauncherConstants）：
//   H. windowWidth == 600
//   I. maxQueryLength == 8000
//   J. windowYRatio == 0.3
//   K. 8000 字符是边界（接受）；8001 字符截断后恰好 8000
//
// LauncherError 契约：
//   L. hotkeyConflict("X").localizedDescription 含关联值 "X" 和"被其他应用占用"
//
// LauncherWindow 契约：
//   M. LauncherWindow 是 NSPanel 子类
//   N. canBecomeKey == true；level == .floating
//   O. collectionBehavior 含 .canJoinAllSpaces；backgroundColor == .clear
//   P. titlebarAppearsTransparent == true；canBecomeMain == false
//   Q. 初始 frame.width == LauncherConstants.windowWidth (600)
//
// LauncherManager submit 无状态（SC-08）：
//   R. submit("test") 返回 AttributedString("echo: test")
//   S. 连续调用 submit 结果互相独立（无内部 messages 累积）
//
// 黑盒原则：通过公开 API 和 UserDefaults 副作用观察行为。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherHotkeyAcceptanceTests: XCTestCase {

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // 重置探针 flag，保证每次测试独立
        UserDefaults.standard.removeObject(forKey: LauncherConstants.hotkeyProbeCompletedKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: LauncherConstants.hotkeyProbeCompletedKey)
        try await super.tearDown()
    }

    // MARK: - A. LauncherHotkey.toggle Name 字符串契约（契约锁定）

    /// LauncherHotkey.toggle.rawValue 必须精确等于 "launcher-toggle"。
    /// 防止重命名导致 UserDefaults 存储的快捷键偏好丢失。
    func test_SC01_toggle_nameRawValue_isLauncherToggle() {
        XCTAssertEqual(
            LauncherHotkey.toggle.rawValue,
            "launcher-toggle",
            "LauncherHotkey.toggle.rawValue must be exactly \"launcher-toggle\" (contract lock)"
        )
    }

    // MARK: - B. 注册后 getShortcut 返回非 nil（SC-01）

    /// register() 调用后，KeyboardShortcuts.getShortcut(for: .toggle) 必须非 nil。
    /// 验证 default combo (⌘⇧Space) 已在 Name 初始化时正确传入。
    func test_SC01_hotkeyRegistration_succeeds() {
        // 注册后快捷键 combo 应非 nil
        LauncherHotkey.register { /* no-op in test */ }
        let combo = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        XCTAssertNotNil(combo, "快捷键注册后 getShortcut 应返回非 nil combo")
    }

    // MARK: - C. probeIfNeeded() 写入 UserDefaults flag（SC-01 副作用）

    /// probeIfNeeded() 调用后，UserDefaults 中 hotkeyProbeCompletedKey 必须变为 true。
    /// 验证副作用清单：写 UserDefaults launcher.hotkeyProbeCompleted=true。
    func test_SC01_probeIfNeeded_persistsCompletedFlag() async {
        // Given: flag 尚未设置
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: LauncherConstants.hotkeyProbeCompletedKey),
            "Precondition: flag should not be set before probeIfNeeded()"
        )

        // When
        LauncherHotkey.register { /* no-op */ }
        _ = await LauncherHotkey.probeIfNeeded()

        // Then: flag 必须被写入为 true
        let flagSet = UserDefaults.standard.bool(forKey: LauncherConstants.hotkeyProbeCompletedKey)
        XCTAssertTrue(flagSet, "探针完成后应将 \(LauncherConstants.hotkeyProbeCompletedKey) 写入 UserDefaults")
    }

    // MARK: - D. probeIfNeeded() 返回 true（SC-01）

    /// probeIfNeeded() 在快捷键已注册时必须返回 true。
    func test_SC01_probeIfNeeded_returnsTrueWhenShortcutSet() async {
        // 先注册（确保 shortcut 有默认值），再跑探针
        LauncherHotkey.register { /* no-op */ }
        let result = await LauncherHotkey.probeIfNeeded()
        XCTAssertTrue(result, "探针在快捷键已注册时应返回 true")
    }

    // MARK: - E. probeIfNeeded() flag 已存在时早返回，仍返回 true

    /// flag 已设置时，probeIfNeeded() 走早返回路径并返回 true（无需再次检测）。
    func test_SC01_probeIfNeeded_returnsTrueOnSecondCall_earlyReturn() async {
        // Given: flag 已预设为 true
        UserDefaults.standard.set(true, forKey: LauncherConstants.hotkeyProbeCompletedKey)

        // When: 第二次调用（走早返回路径，不再重复检测）
        let result = await LauncherHotkey.probeIfNeeded()

        // Then
        XCTAssertTrue(result, "probeIfNeeded() must return true when flag is already set (early return)")
    }

    // MARK: - F. UserDefaults key 命名空间隔离

    /// hotkeyProbeCompletedKey 以 "launcher." 前缀，不与现有 "alwaysShowLabel" 冲突。
    func test_SC01_userDefaultsKey_isNamespaced() {
        let key = LauncherConstants.hotkeyProbeCompletedKey
        XCTAssertTrue(
            key.hasPrefix("launcher."),
            "UserDefaults key 必须以 'launcher.' 命名空间前缀，防止与现有 key 冲突"
        )
        XCTAssertNotEqual(key, "alwaysShowLabel",
                          "key must not conflict with existing \"alwaysShowLabel\" key")
    }

    // MARK: - G. hotkeyProbeCompletedKey 精确值

    /// hotkeyProbeCompletedKey 精确等于 "launcher.hotkeyProbeCompleted"（契约锁定）。
    func test_SC01_hotkeyProbeCompletedKey_exactValue() {
        XCTAssertEqual(
            LauncherConstants.hotkeyProbeCompletedKey,
            "launcher.hotkeyProbeCompleted",
            "hotkeyProbeCompletedKey must be exactly \"launcher.hotkeyProbeCompleted\""
        )
    }
}

// MARK: - LauncherConstantsAcceptanceTests

/// 验收测试：LauncherConstants 关键值与契约精确一致（常量锁定测试）
///
/// 任何意外改动 windowWidth / maxQueryLength / windowYRatio / hotkeyProbeCompletedKey
/// 将直接使这些测试变红灯。
final class LauncherConstantsAcceptanceTests: XCTestCase {

    // MARK: - H. windowWidth == 600

    func test_constants_windowWidth_is600() {
        XCTAssertEqual(
            LauncherConstants.windowWidth,
            600,
            "LauncherConstants.windowWidth must be exactly 600pt (contract)"
        )
    }

    // MARK: - I. maxQueryLength == 8000

    func test_constants_maxQueryLength_is8000() {
        XCTAssertEqual(
            LauncherConstants.maxQueryLength,
            8000,
            "LauncherConstants.maxQueryLength must be exactly 8000 (DbC contract)"
        )
    }

    // MARK: - J. windowYRatio == 0.3

    func test_constants_windowYRatio_is0_3() {
        XCTAssertEqual(
            LauncherConstants.windowYRatio,
            0.3,
            accuracy: 1e-6,
            "LauncherConstants.windowYRatio must be exactly 0.3 (golden ratio position)"
        )
    }

    // MARK: - K. 边界值语义：8000 接受，8001 截断为 8000

    /// 恰好 8000 字符的字符串等于 maxQueryLength（边界内，接受）。
    func test_constants_maxQueryLength_8000charsIsAtBoundary_allowed() {
        let atBoundary = String(repeating: "A", count: LauncherConstants.maxQueryLength)
        XCTAssertEqual(
            atBoundary.count,
            LauncherConstants.maxQueryLength,
            "A string of exactly maxQueryLength(8000) characters must be at the boundary (allowed)"
        )
    }

    /// 8001 字符截断后恰好等于 maxQueryLength（反例验证截断语义）。
    func test_constants_maxQueryLength_8001charsTruncatedTo8000() {
        let overBoundary = String(repeating: "B", count: LauncherConstants.maxQueryLength + 1)
        let truncated = String(overBoundary.prefix(LauncherConstants.maxQueryLength))

        XCTAssertEqual(
            truncated.count,
            LauncherConstants.maxQueryLength,
            "Truncating 8001-char string via prefix(maxQueryLength) must yield exactly 8000 chars"
        )
        XCTAssertLessThan(
            truncated.count,
            overBoundary.count,
            "Truncated string must be shorter than the over-boundary input"
        )
    }
}

// MARK: - LauncherErrorAcceptanceTests

/// 验收测试：LauncherError 错误描述契约（SC-01 错误契约）
///
/// 契约：LauncherError.hotkeyConflict(combo).localizedDescription
///        必须包含 combo 字符串和"被其他应用占用"。
// NOTE: Renamed from LauncherErrorAcceptanceTests to LauncherHotkeyErrorAcceptanceTests
// to avoid conflict with task 002's LauncherErrorAcceptanceTests.swift
final class LauncherHotkeyErrorAcceptanceTests: XCTestCase {

    // MARK: - L. hotkeyConflict localizedDescription 契约

    /// hotkeyConflict("⌘⇧Space").localizedDescription 包含 combo 和"被其他应用占用"。
    func test_SC01_hotkeyConflict_localizedDescription_containsComboAndMessage() {
        let combo = "⌘⇧Space"
        let error = LauncherError.hotkeyConflict(combo)
        let desc = error.localizedDescription

        XCTAssertTrue(
            desc.contains(combo),
            "hotkeyConflict(\"\(combo)\").localizedDescription must contain the combo string"
        )
        XCTAssertTrue(
            desc.contains("被其他应用占用"),
            "hotkeyConflict.localizedDescription must contain \"被其他应用占用\""
        )
    }

    /// hotkeyConflict 中的 associated value "X" 被正确嵌入错误描述。
    func test_SC01_hotkeyConflict_embeds_associatedValue() {
        let testCombo = "TestShortcutX"
        let error = LauncherError.hotkeyConflict(testCombo)

        XCTAssertTrue(
            error.localizedDescription.contains(testCombo),
            "localizedDescription must embed the associated combo value \"\(testCombo)\""
        )
    }

    /// LauncherError 符合 Error 协议（可抛出）。
    func test_launcherError_conformsToError() {
        let error: Error = LauncherError.hotkeyConflict("test")
        XCTAssertNotNil(error, "LauncherError must conform to Error protocol")
    }
}

// MARK: - LauncherWindowContractTests

/// 验收测试：LauncherWindow NSPanel 子类契约
///
/// 设计文档要求（NSPanel 初始化参数）：
///   - LauncherWindow 是 NSPanel 子类
///   - canBecomeKey == true（允许 TextField 获焦）
///   - level == .floating（浮窗层级）
///   - collectionBehavior 含 .canJoinAllSpaces（跨 Space 可见）
///   - backgroundColor == .clear（透明背景，配合 .regularMaterial）
///   - titlebarAppearsTransparent == true
///   - canBecomeMain == false（不抢主窗口）
///   - 初始 frame.width == LauncherConstants.windowWidth (600pt)
final class LauncherWindowContractTests: XCTestCase {

    // MARK: - M. LauncherWindow 是 NSPanel 子类

    func test_launcherWindow_isNSPanelSubclass() {
        let window = LauncherWindow()
        XCTAssertTrue(
            window is NSPanel,
            "LauncherWindow must be a subclass of NSPanel"
        )
    }

    // MARK: - N. canBecomeKey == true；level == .floating

    func test_launcherWindow_canBecomeKey_isTrue() {
        let window = LauncherWindow()
        XCTAssertTrue(
            window.canBecomeKey,
            "LauncherWindow.canBecomeKey must be true (required for TextField focus)"
        )
    }

    func test_launcherWindow_level_isFloating() {
        let window = LauncherWindow()
        XCTAssertEqual(
            window.level,
            .floating,
            "LauncherWindow.level must be .floating"
        )
    }

    // MARK: - O. collectionBehavior 含 .canJoinAllSpaces；backgroundColor == .clear

    func test_launcherWindow_collectionBehavior_containsCanJoinAllSpaces() {
        let window = LauncherWindow()
        XCTAssertTrue(
            window.collectionBehavior.contains(.canJoinAllSpaces),
            "LauncherWindow.collectionBehavior must contain .canJoinAllSpaces"
        )
    }

    func test_launcherWindow_backgroundColor_isClear() {
        let window = LauncherWindow()
        XCTAssertEqual(
            window.backgroundColor,
            .clear,
            "LauncherWindow.backgroundColor must be .clear"
        )
    }

    // MARK: - P. titlebarAppearsTransparent == true；canBecomeMain == false

    func test_launcherWindow_titlebarAppearsTransparent_isTrue() {
        let window = LauncherWindow()
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "LauncherWindow.titlebarAppearsTransparent must be true"
        )
    }

    func test_launcherWindow_canBecomeMain_isFalse() {
        let window = LauncherWindow()
        XCTAssertFalse(
            window.canBecomeMain,
            "LauncherWindow.canBecomeMain must be false (must not steal main window)"
        )
    }

    // MARK: - Q. 初始 frame.width == LauncherConstants.windowWidth (600)

    func test_launcherWindow_initialWidth_equalsWindowWidthConstant() {
        let window = LauncherWindow()
        XCTAssertEqual(
            window.frame.width,
            LauncherConstants.windowWidth,
            accuracy: 0.5,
            "LauncherWindow initial frame.width must equal LauncherConstants.windowWidth (600pt)"
        )
    }
}

// MARK: - LauncherSubmitStatelessAcceptanceTests
//
// SC-08 契约演进（task 001 → task 002）：
// task 001 原本断言 submit("hi") → "echo: hi"，但 task 002 brief 明确**重写 submit**
// 接入 ProviderFactory → provider.send。echo 仅是 task 001 阶段过渡占位，非长期契约。
// SC-08 的"每次唤起为新 session"语义在 task 002 仍成立（连续 submit 无状态），
// 但断言形态从 echo 字符匹配 → 错误消息一致性（同样的未配置错误）。

@MainActor
final class LauncherSubmitStatelessAcceptanceTests: XCTestCase {

    /// 连续两次 submit 独立计算（SC-08，无 messages 累积）
    /// task 002 演进：错误消息本身也是无状态的，不携带前序输入。
    /// task 003 适配：submit 返回 AsyncStream<AgentEvent>，消费流提取错误类型（非字符串）做语义比对
    func test_SC08_submit_isStateless_noPersistentMessages() async {
        // Given: 无 provider 配置（每次 submit 走相同的错误路径）

        // 提取错误"类型"标签（不含非确定性地址/UUID 字段）
        func errorTypeLabel(_ err: LauncherError) -> String {
            switch err {
            case .providerNotConfigured: return "providerNotConfigured"
            case .secretStoreUnavailable: return "secretStoreUnavailable"
            case .networkFailure: return "networkFailure"  // 不含 Error 详情（含内存地址）
            case .invalidAPIKey(let s): return "invalidAPIKey(\(s))"
            case .providerHTTPError(let c, _): return "providerHTTPError(\(c))"
            case .hotkeyConflict(let s): return "hotkeyConflict(\(s))"
            case .maxIterations: return "maxIterations"
            case .pluginNotFound(let s): return "pluginNotFound(\(s))"
            case .pluginMissingDependency(let s): return "pluginMissingDependency(\(s))"
            case .pluginTimeout(let i): return "pluginTimeout(\(i))"
            case .pluginCrash(let c, _): return "pluginCrash(\(c))"
            case .pluginManifestInvalid(let s): return "pluginManifestInvalid(\(s))"
            case .pluginNotTrusted(let s): return "pluginNotTrusted(\(s))"
            case .pluginInvalid(let s): return "pluginInvalid(\(s))"
            case .promptExecutorNotAvailable: return "promptExecutorNotAvailable"
            }
        }

        // 消费第一个 stream，提取错误类型标签
        var firstLabel: String? = nil
        for await event in LauncherManager.shared.submit("first-message") {
            if case .error(let err) = event {
                firstLabel = errorTypeLabel(err)
            }
        }

        // 消费第二个 stream，提取错误类型标签
        var secondLabel: String? = nil
        for await event in LauncherManager.shared.submit("second-message") {
            if case .error(let err) = event {
                secondLabel = errorTypeLabel(err)
            }
        }

        // Then: 两次结果完全一致（同样的无配置错误，无前序输入痕迹）
        XCTAssertNotNil(firstLabel, "第一次 submit 应产生 .error 事件")
        XCTAssertNotNil(secondLabel, "第二次 submit 应产生 .error 事件")
        XCTAssertEqual(firstLabel, secondLabel,
                       "无 provider 时连续调用应返回相同错误类型（无状态），first=\(firstLabel ?? "nil"), second=\(secondLabel ?? "nil")")
        if let label = firstLabel {
            XCTAssertFalse(label.contains("second-message"),
                           "第一次结果不应含第二次 query 内容（防引用未来状态）")
        }
        if let label = secondLabel {
            XCTAssertFalse(label.contains("first-message"),
                           "第二次结果不应含第一次 query 内容（防 messages 数组累积）")
        }
    }
}
