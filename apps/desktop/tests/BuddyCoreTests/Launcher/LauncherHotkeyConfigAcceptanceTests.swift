import XCTest
import KeyboardShortcuts
@testable import BuddyCore

// MARK: - LauncherHotkeyConfigAcceptanceTests
//
// 红队验收测试：socket hotkey 命令契约（hotkey_set / hotkey_show / hotkey_clear）
//
// 设计文档契约（state.md ### 契约规约 契约 2）：
//   请求：
//     - action ∈ {hotkey_set, hotkey_show, hotkey_clear}
//     - hotkey_set 参数：key:String（非空）+ modifiers:[String]（元素 ∈ {command,shift,control,option}）
//   响应（成功）：{status:"ok", data:{combo:String, isDefault:Bool}}
//   响应（失败）：{status:"error", message:String}（仅参数非法路径）
//   hotkey_clear → KeyboardShortcuts.reset(.toggle) 回 default（非 setShortcut(nil) 清除）
//   combo 格式与 UI Recorder 一致（如 "⌃Space"）
//
// 覆盖场景（state.md 验证方案 + brainstorm A1-G3）：
//   D1: hotkey_show 返回 combo + isDefault
//   E2: 非法 modifiers / 空 key 被拒（{status:"error"}）
//   F2: 坏值升级清理（迁移逻辑）
//   G2: 重启持久化（UserDefaults）
//   契约 2 schema 逐字段断言
//
// 注：本测试通过真实 QueryHandler 注入（对齐 QueryHandlerTests 模式）。
// setShortcut/reset 直接操作 KeyboardShortcuts UserDefaults（库单一真相源）。
// 测试间隔离：每个 case 在 setUp 中 reset + clear UserDefaults。
// 测试 WILL NOT compile 直到蓝队合并 hotkey_* 分支 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherHotkeyConfigAcceptanceTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var eventStore: EventStore!
    private var handler: QueryHandler!

    /// KeyboardShortcuts 库在 UserDefaults 存储 toggle 偏好的 key。
    /// 库格式：`KeyboardShortcuts_<rawValue>`。
    private let hotkeyDefaultsKey = "KeyboardShortcuts_launcher-toggle"

    override func setUp() async throws {
        try await super.setUp()
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        eventStore = manager.eventStore
        handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: eventStore)

        // 清理库 UserDefaults：保证每个测试从干净状态开始（isDefault 等断言不被前序 case 污染）
        UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        KeyboardShortcuts.reset(LauncherHotkey.toggle)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        KeyboardShortcuts.reset(LauncherHotkey.toggle)
        try await super.tearDown()
    }

    // MARK: - 响应解析辅助

    /// 将 QueryHandler 返回的 Data 解析为 JSON dict。
    private func parseResponse(_ data: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("响应必须是合法 JSON dict")
            return [:]
        }
        return json
    }

    // MARK: - D1: hotkey_show 返回当前 combo + isDefault

    /// D1：hotkey_show 必须返回 {status:"ok", data:{combo, isDefault}}。
    /// 默认状态下（无自定义）combo 应为 Ctrl+Space 且 isDefault == true。
    func test_D1_hotkeyShow_returnsOkWithComboAndIsDefault() async {
        let data = await handler.handle(query: ["action": "hotkey_show"])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "D1: hotkey_show 必须返回 status:\"ok\"，actual=\(json)")
        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("D1: hotkey_show 响应必须含 data 字段（dict）")
            return
        }
        XCTAssertNotNil(payload["combo"],
                        "D1: data 必须含 combo 字段（String）")
        XCTAssertNotNil(payload["isDefault"],
                        "D1: data 必须含 isDefault 字段（Bool）")
    }

    /// D1 + 默认 combo 断言：hotkey_show 在默认状态下 isDefault == true 且 combo 含 "Space"（或本地化等价 "空格"）。
    func test_D1_hotkeyShow_defaultState_isDefaultTrue() async {
        let data = await handler.handle(query: ["action": "hotkey_show"])
        let json = parseResponse(data)
        let payload = json["data"] as? [String: Any] ?? [:]

        XCTAssertEqual(payload["isDefault"] as? Bool, true,
                       "D1: 默认状态下 hotkey_show.data.isDefault 必须为 true")
        let combo = payload["combo"] as? String ?? ""
        // combo 含 Space 或本地化的 "空格"（KeyboardShortcuts 库 space_key 在 zh locale 渲染）
        XCTAssertTrue(combo.contains("Space") || combo.contains("空格"),
                      "D1: 默认 combo 必须含 \"Space\"（Ctrl+Space，或本地化等价），actual=\(combo)")
    }

    // MARK: - 契约 2: hotkey_set 合法参数返回 ok + isDefault false

    /// hotkey_set 合法参数（key + modifiers ∈ {command,shift,control,option}）
    /// 必须返回 {status:"ok", data:{combo, isDefault:false}}。
    func test_contract2_hotkeySet_validParams_returnsOkNotDefault() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command", "shift"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "契约 2: 合法 hotkey_set 必须返回 status:\"ok\"，actual=\(json)")
        let payload = json["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["isDefault"] as? Bool, false,
                       "契约 2: 自定义热键后 isDefault 必须为 false")
        XCTAssertNotNil(payload["combo"],
                        "契约 2: 成功响应必须含 combo 字段")
    }

    // MARK: - E2: 非法 modifiers 被拒

    /// E2：modifiers 含非法字符串（如 "foobar"）必须返回 {status:"error"}。
    /// 不允许静默忽略非法元素或 fallback 到默认。
    func test_E2_hotkeySet_invalidModifier_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "space",
            "modifiers": ["foobar"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "E2: 非法 modifier \"foobar\" 必须被拒绝（status:\"error\"），actual=\(json)")
        XCTAssertNotNil(json["message"],
                        "E2: error 响应必须含 message 字段")
    }

    /// E2：modifiers 含部分合法 + 部分非法（如 ["control", "BANANA"]）必须整体被拒。
    func test_E2_hotkeySet_partialInvalidModifier_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["control", "BANANA"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "E2: modifiers 含任一非法元素必须整体拒绝，actual=\(json)")
    }

    /// E2：modifiers 含 option（合法集 {command,shift,control,option} 边界成员）应接受。
    /// 反例验证：边界成员 "option" 不应被误拒。
    func test_E2_hotkeySet_optionModifier_accepted() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["option"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "E2: \"option\" 在合法 modifier 集内，应接受，actual=\(json)")
    }

    // MARK: - E2: 空 key 被拒

    /// E2：key 缺失（无 key 字段）必须返回 {status:"error"}。
    func test_E2_hotkeySet_missingKey_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "modifiers": ["control"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "E2: 缺失 key 字段必须被拒绝，actual=\(json)")
    }

    /// E2：key 为空字符串必须返回 {status:"error"}。
    func test_E2_hotkeySet_emptyKey_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "",
            "modifiers": ["control"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "E2: 空 key 字符串必须被拒绝，actual=\(json)")
    }

    // MARK: - 契约 2: hotkey_set 参数类型契约

    /// hotkey_set 的 key 必须是 String 类型。传 Int 应被拒（不静默转换）。
    func test_contract2_hotkeySet_nonStringKey_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": 123,
            "modifiers": ["control"],
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "契约 2: 非 String key（Int）必须被拒绝，actual=\(json)")
    }

    /// hotkey_set 的 modifiers 必须是 [String]。传单个 String 应被拒。
    func test_contract2_hotkeySet_nonArrayModifiers_rejected() async {
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": "control",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "契约 2: 非 [String] modifiers（String）必须被拒绝，actual=\(json)")
    }

    // MARK: - 契约 2: hotkey_clear 回 default（非 setShortcut(nil) 清除）

    /// hotkey_clear 必须回 default（isDefault == true），不是清除（isDefault 应仍可读 default）。
    ///
    /// 关键：设计文档明确 `KeyboardShortcuts.reset(.toggle)` 回 default，
    /// **非** `setShortcut(nil)`（后者清除导致 getShortcut 返回 nil）。
    /// 状态转移序列：
    ///   [初始] default (isDefault=true)
    ///   → [set 自定义] isDefault=false
    ///   → [clear] isDefault=true（回 default，非空 combo）
    func test_contract2_hotkeyClear_resetsToDefault_notClear() async {
        // Step 1: 先 set 一个自定义热键，确保不是默认态
        let setResp = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command", "shift"],
        ])
        let setJson = parseResponse(setResp)
        XCTAssertEqual(setJson["status"] as? String, "ok", "Precondition: 自定义 set 应成功")
        let setPayload = setJson["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(setPayload["isDefault"] as? Bool, false,
                       "状态转移 [set 自定义]: isDefault 必须为 false")

        // Step 2: clear → 回 default
        let clearResp = await handler.handle(query: ["action": "hotkey_clear"])
        let clearJson = parseResponse(clearResp)

        XCTAssertEqual(clearJson["status"] as? String, "ok",
                       "契约 2: hotkey_clear 必须返回 status:\"ok\"")
        let clearPayload = clearJson["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(clearPayload["isDefault"] as? Bool, true,
                       "状态转移 [clear]: hotkey_clear 必须回 default（isDefault=true），" +
                       "不是 setShortcut(nil) 清除（后者 isDefault 不可读 default combo）")
        let combo = clearPayload["combo"] as? String ?? ""
        XCTAssertFalse(combo.isEmpty,
                       "契约 2: hotkey_clear 后 combo 必须非空（回 default Ctrl+Space），" +
                       "setShortcut(nil) 清除会导致 combo 为空/不可用")
        XCTAssertTrue(combo.contains("Space") || combo.contains("空格"),
                      "契约 2: hotkey_clear 后 combo 应为 default Ctrl+Space（或本地化等价），actual=\(combo)")
    }

    // MARK: - 契约 2: 未知 action 路径

    /// 未知 action 必须返回 error（QueryHandler 既有 default 分支）。
    /// 确保新增 hotkey_* case 没破坏既有 unknown action 契约。
    func test_contract2_unknownAction_returnsError() async {
        let data = await handler.handle(query: ["action": "totally_unknown_hotkey_thing"])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "契约 2: 未知 action 必须返回 status:\"error\"，actual=\(json)")
    }

    // MARK: - G2: 重启持久化（UserDefaults 副作用）

    /// G2：hotkey_set 成功后，KeyboardShortcuts 库必须把偏好持久化到
    /// UserDefaults key "KeyboardShortcuts_launcher-toggle"。
    /// 重启后 getShortcut 读取同一 UserDefaults → 持久化语义。
    ///
    /// 注：库 reset 后会持久化 default shortcut 编码到 UserDefaults（非 nil），
    /// 故本测试通过「set 前后的 UserDefaults 值不同」证明持久化写入，而非「从 nil 变非 nil」。
    func test_G2_hotkeySet_persistsToUserDefaults() async {
        // Given: 记录 set 前的 UserDefaults 值（reset 后库写入 default 编码，非 nil）
        let beforeSet = UserDefaults.standard.object(forKey: hotkeyDefaultsKey) as? String

        // When: set 自定义热键
        let data = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command"],
        ])
        let json = parseResponse(data)
        XCTAssertEqual(json["status"] as? String, "ok", "G2: set 必须成功")

        // Then: UserDefaults 必须有持久化值，且与 set 前不同（证明新值写入）
        let afterSet = UserDefaults.standard.object(forKey: hotkeyDefaultsKey) as? String
        XCTAssertNotNil(afterSet,
                        "G2: hotkey_set 后 UserDefaults[\(hotkeyDefaultsKey)] 必须有持久化值（重启可读）")
        XCTAssertNotEqual(afterSet, beforeSet,
                          "G2: set 后 UserDefaults 值必须改变（证明新 combo 写入），before=\(String(describing: beforeSet)), after=\(String(describing: afterSet))")
    }

    /// G2 补充：hotkey_clear 后 UserDefaults 偏好清除（回 default = 库内部无自定义值）。
    /// 这是持久化的对称断言（set 写入 → clear 清除）。
    func test_G2_hotkeyClear_clearsUserDefaultsCustomization() async {
        // 先 set 写入 UserDefaults
        _ = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command"],
        ])
        XCTAssertNotNil(UserDefaults.standard.object(forKey: hotkeyDefaultsKey),
                        "G2 precondition: set 后 UserDefaults 应有值")

        // clear 应回 default（库 reset 清除自定义，UserDefaults 回到无自定义值状态）
        _ = await handler.handle(query: ["action": "hotkey_clear"])

        // reset 后 getShortcut 应返回 default（库逻辑），UserDefaults 自定义值应被清除
        // 注：库 reset 后 UserDefaults 可能是 nil 或 default 序列化值，关键是 getShortcut 返回 default
        let defaultShortcut = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        XCTAssertNotNil(defaultShortcut,
                        "G2: hotkey_clear 后 getShortcut 必须返回 default（非 nil），" +
                        "证明 reset 而非 setShortcut(nil)")
    }

    // MARK: - D1 + G2: set 后 show 反映新值（状态转移序列）

    /// D1 + G2：set 自定义后立即 show，combo 必须反映新值且 isDefault == false。
    /// 验证 set → show 状态转移的即时一致性（非仅终态断言）。
    func test_D1G2_setThenShow_reflectsNewValueImmediately() async {
        // [初始 show] 默认态
        let show0 = parseResponse(await handler.handle(query: ["action": "hotkey_show"]))
        let payload0 = show0["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload0["isDefault"] as? Bool, true,
                       "状态转移 [初始 show]: isDefault 必须为 true")

        // [set 自定义]
        let setResp = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command", "shift"],
        ])
        XCTAssertEqual(parseResponse(setResp)["status"] as? String, "ok")

        // [show 后] 必须反映新值
        let show1 = parseResponse(await handler.handle(query: ["action": "hotkey_show"]))
        let payload1 = show1["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload1["isDefault"] as? Bool, false,
                       "状态转移 [set 后 show]: isDefault 必须为 false（反映自定义）")
        let combo1 = payload1["combo"] as? String ?? ""
        XCTAssertTrue(combo1.contains("P"),
                      "状态转移 [set 后 show]: combo 必须反映新 key \"P\"，actual=\(combo1)")
    }

    // MARK: - F2: 坏值升级清理（迁移逻辑单元测试）

    /// F2：启动迁移必须清理不兼容的旧 UserDefaults 值。
    ///
    /// 设计文档 T6：LauncherManager.setup 检测迁移标志 `launcher.hotkeyMigrationV1`，
    /// 标志未置时清理 `KeyboardShortcuts_launcher-toggle` + 置标志（一次性幂等）。
    ///
    /// 状态转移序列：
    ///   [迁移前] UserDefaults 有坏值 + 标志未置
    ///   → [迁移] 清理坏值 + 置标志
    ///   → [幂等] 第二次迁移不再清理（标志已置）
    func test_F2_migration_clearsIncompatibleLegacyValue() async {
        let migrationFlag = "launcher.hotkeyMigrationV1"

        // 清理上次测试残留
        UserDefaults.standard.removeObject(forKey: migrationFlag)
        UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: migrationFlag)
            UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        }

        // Given: 注入坏值（模拟升级前旧库格式不兼容场景）
        UserDefaults.standard.set("<<corrupted-legacy-bytes>>", forKey: hotkeyDefaultsKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: migrationFlag),
                       "F2 precondition: 迁移标志初始应为 false")

        // When: 调用迁移（蓝队需在 LauncherHotkey 或 LauncherManager 暴露的迁移入口）
        // 黑盒视角：通过公开迁移函数触发
        LauncherHotkey.migrateLegacyIfNeeded()

        // Then: 坏值必须被清理 + 标志置位
        let legacyAfter = UserDefaults.standard.object(forKey: hotkeyDefaultsKey)
        // 坏字符串必须被清除（可能是 nil 或被库 reset 为合法值，但不应是原始坏字符串）
        XCTAssertNotEqual(legacyAfter as? String, "<<corrupted-legacy-bytes>>",
                          "F2: 迁移后坏值必须被清理，不应保留原始不兼容字符串")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: migrationFlag),
                      "F2: 迁移完成后必须置位 launcher.hotkeyMigrationV1=true")
    }

    /// F2 幂等性：迁移标志已置时，再次调用不应清理（即使有值）。
    /// 防止每次启动都清理用户自定义。
    func test_F2_migration_isIdempotent_whenFlagAlreadySet() async {
        let migrationFlag = "launcher.hotkeyMigrationV1"

        UserDefaults.standard.removeObject(forKey: migrationFlag)
        UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: migrationFlag)
            UserDefaults.standard.removeObject(forKey: hotkeyDefaultsKey)
        }

        // Given: 标志已置 + 一个用户自定义值（合法的库格式，模拟用户改键后）
        UserDefaults.standard.set(true, forKey: migrationFlag)
        let userCustomValue = "<<user-custom-legit-value>>"
        UserDefaults.standard.set(userCustomValue, forKey: hotkeyDefaultsKey)

        // When: 再次迁移
        LauncherHotkey.migrateLegacyIfNeeded()

        // Then: 用户自定义值不应被清理（幂等：标志已置则跳过）
        let valueAfter = UserDefaults.standard.object(forKey: hotkeyDefaultsKey) as? String
        XCTAssertEqual(valueAfter, userCustomValue,
                       "F2 幂等: 迁移标志已置时不应清理用户自定义值，actual=\(String(describing: valueAfter))")
    }

    // MARK: - A3: Recorder 反映真实生效热键（黑盒等价断言）

    /// A3：UI Recorder（RecorderCocoa）必须反映 getShortcut 返回的真实热键。
    ///
    /// 黑盒视角：无法在 unit test 中实例化 RecorderCocoa（需 NSWindow/run loop），
    /// 改为断言契约前提 —— getShortcut 返回值与 setShortcut 写入值一致，
    /// 即「库的真相源单一」，UI Recorder 读取同一源。
    ///
    /// 状态转移序列：
    ///   [set ⌘P] → getShortcut 返回 ⌘P
    ///   [reset] → getShortcut 返回 default Ctrl+Space
    func test_A3_getShortcut_reflectsSetShortcut_singleSourceOfTruth() async {
        // [初始] default
        let initial = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        XCTAssertNotNil(initial, "A3 初始: getShortcut 应返回 default（非 nil）")

        // [set ⌘P]
        _ = await handler.handle(query: [
            "action": "hotkey_set",
            "key": "p",
            "modifiers": ["command"],
        ])
        let afterSet = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        XCTAssertNotNil(afterSet, "A3 [set 后]: getShortcut 不应为 nil")
        XCTAssertEqual(afterSet?.key, .p,
                       "A3 [set 后]: getShortcut.key 必须反映 setShortcut 写入的 .p")
        XCTAssertTrue(afterSet?.modifiers.contains(.command) ?? false,
                      "A3 [set 后]: getShortcut.modifiers 必须反映 .command")

        // [reset] 回 default
        _ = await handler.handle(query: ["action": "hotkey_clear"])
        let afterClear = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        XCTAssertEqual(afterClear?.key, .space,
                       "A3 [clear 后]: getShortcut.key 必须回 default .space")
        XCTAssertTrue(afterClear?.modifiers.contains(.control) ?? false,
                      "A3 [clear 后]: getShortcut.modifiers 必须回 default 含 .control")
        XCTAssertFalse(afterClear?.modifiers.contains(.command) ?? true,
                       "A3 [clear 后]: getShortcut.modifiers 不应含 .command（回 Ctrl+Space）")
    }
}
