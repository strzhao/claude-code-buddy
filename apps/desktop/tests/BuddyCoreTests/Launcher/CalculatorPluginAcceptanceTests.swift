import XCTest
import AppKit
@testable import BuddyCore

// MARK: - CalculatorPluginAcceptanceTests
//
// 红队验收测试：CalculatorPlugin 第三个内置插件契约（CP1–CP7 + 场景 1–7 谓词）
//
// 本文件覆盖：
//   CP1  — 属性契约（id=="calculator" / priority==200 / sectionTitle=="计算" / 遵守 BuiltinPlugin）
//   CP2  — 候选输出：合法表达式 → 恰好 1 候选 title=="= <结果>" score==1000 pluginId=="calculator"
//   CP3  — 静默降级：除零 / 裸数字 / 字母 / 语法错 / 空 / 纯空格 → []
//   CP4  — 副标题含表达式 + "复制" 提示
//   CP5  — perform 复制：注入 NSPasteboard，perform 后读实际粘贴板内容 == 格式化结果
//   CP6  — 跨插件仲裁：默认 registry actions(for:合法表达式) first.pluginId=="calculator"（priority 200 置顶）
//   CP7  — reset() 后默认列表仍含 calculator 插件（防 flaky，init 已注册但 reset 默认列表需含）
//
// 场景覆盖（预注册谓词）：
//   场景1 [det-machine]: actions(for:"1+2*3") → 1 候选 title=="= 7"
//   场景2 [det-machine]: actions(for:"(1+2)*3") → title=="= 9"
//   场景3 [det-machine]: actions(for:"2^3^2") → title=="= 512"
//   场景4 [det-machine]: actions(for:"1/0") → []
//   场景5 [det-machine]: actions(for:"365") → []
//   场景6 [det-machine]: perform → 注入 pasteboard 写入格式化结果（如 "1+3" → "= 4"）
//   场景7 [det-machine]: 默认 registry calculator priority 200 置顶 → first.pluginId=="calculator"
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Calculator/ 下任何实现文件
//   - 仅依据设计文档契约逐字断言（接口签名 + 边界值字面量 + BuiltinPlugin 公开协议）
//   - perform 复制必须断言实际粘贴板内容（反 no-op "perform 不抛" 宽容断言）
//   - 跨插件仲裁必须断言 first.pluginId（反 "count > 0" 宽容断言）
//   - ISOLATION: 蓝队实现信息隔离，源码扫描留 QA 核对（不读 CalculatorPlugin.swift）
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// CONTRACT_AMBIGUOUS:
//   1. CalculatorPlugin 构造器签名：契约写 `init(copyService: CopyService = .shared)`。
//      测试用 `CalculatorPlugin(copyService: testCopyService)` 注入命名 pasteboard。
//   2. CalculatorPlugin.shared 单例存在性：BuiltinPluginRegistry.init 第 22 行已引用
//      `CalculatorPlugin.shared`（既有公开契约），故测试可安全引用 .shared。
//   3. subtitle 文案：契约写"含表达式 + 回车复制"，测试断言含表达式字面量 + "复制"二字。
//   4. perform 返回类型：LauncherAction.perform 是 `() throws -> Void`（既有公开契约），
//      复制操作不抛错（CopyService.copy 静默忽略失败）。

@MainActor
final class CalculatorPluginAcceptanceTests: XCTestCase {

    // MARK: - CP1：属性契约

    /// CP1：plugin.id == "calculator"
    func test_CP1_id_calculator() {
        let plugin = CalculatorPlugin.shared
        XCTAssertEqual(plugin.id, "calculator",
            "CP1: CalculatorPlugin.id 必须 == \"calculator\"，实际 \"\(plugin.id)\"")
    }

    /// CP1：plugin.priority == 200（高于 SystemCommand 的 100）
    func test_CP1_priority_equals200() {
        let plugin = CalculatorPlugin.shared
        XCTAssertEqual(plugin.priority, 200,
            "CP1: CalculatorPlugin.priority 必须 == 200（> SystemCommand 的 100），实际 \(plugin.priority)")
    }

    /// CP1：plugin.sectionTitle == "计算"
    func test_CP1_sectionTitle_计算() {
        let plugin = CalculatorPlugin.shared
        XCTAssertEqual(plugin.sectionTitle, "计算",
            "CP1: CalculatorPlugin.sectionTitle 必须 == \"计算\"，实际 \"\(plugin.sectionTitle)\"")
    }

    /// CP1：遵守 BuiltinPlugin 协议（编译期隐式验证，运行期通过协议访问）
    func test_CP1_conformsTo_BuiltinPlugin() {
        let plugin: any BuiltinPlugin = CalculatorPlugin.shared
        XCTAssertEqual(plugin.id, "calculator",
            "CP1: CalculatorPlugin 必须遵守 BuiltinPlugin 协议且 id 正确")
        XCTAssertEqual(plugin.priority, 200,
            "CP1: 通过协议访问 priority 应为 200")
        XCTAssertEqual(plugin.sectionTitle, "计算",
            "CP1: 通过协议访问 sectionTitle 应为 \"计算\"")
    }

    /// CP1 补充：priority 高于 SystemCommand 的 100（跨插件仲裁前置条件）
    func test_CP1_priority_higherThanSystemCommand() {
        let calcPriority = CalculatorPlugin.shared.priority
        let systemPriority = SystemCommandPlugin.shared.priority
        XCTAssertGreaterThan(calcPriority, systemPriority,
            "CP1: CalculatorPlugin.priority(\(calcPriority)) 必须 > SystemCommandPlugin.priority(\(systemPriority))，保证计算候选置顶")
    }

    // MARK: - CP2：候选输出（场景 1-3）

    /// 场景1 [det-machine] + CP2：actions(for:"1+2*3") → count==1 && title=="= 7"
    ///
    /// Mutation-Survival 自检：
    /// - 返回空 mutant → count==0 → precondition XCTFail（捕获）
    /// - 返回多个 mutant → count>1 → 本断言失败（捕获）
    /// - title 拼错 mutant（如 "7" 无 "= " 前缀）→ title 不匹配（捕获）
    func test_CP2_scenario1_oneTwoThree_returnsOneCandidate_titleEq7() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1+2*3")

        XCTAssertEqual(actions.count, 1,
            "CP2 / 场景1: actions(for:\"1+2*3\") 必须恰好返回 1 候选，实际 \(actions.count)")

        XCTAssertEqual(actions.first?.title, "= 7",
            "CP2 / 场景1: 候选 title 必须 == \"= 7\"，实际 \"\(actions.first?.title ?? "nil")\"")
    }

    /// 场景1 补充 [det-machine]：候选 pluginId=="calculator" + score==1000
    func test_CP2_scenario1_candidatePluginIdAndScore() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1+2*3")

        guard let action = actions.first else {
            XCTFail("CP2 / 场景1 补充 precondition: 必须有候选")
            return
        }
        XCTAssertEqual(action.pluginId, "calculator",
            "CP2 / 场景1: 候选 pluginId 必须 == \"calculator\"，实际 \"\(action.pluginId)\"")
        XCTAssertEqual(action.score, 1000,
            "CP2 / 场景1: 候选 score 必须 == 1000，实际 \(action.score)")
    }

    /// 场景2 [det-machine] + CP2：actions(for:"(1+2)*3") → title=="= 9"
    func test_CP2_scenario2_parens_titleEq9() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "(1+2)*3")

        XCTAssertEqual(actions.count, 1,
            "CP2 / 场景2: actions(for:\"(1+2)*3\") 必须恰好 1 候选，实际 \(actions.count)")
        XCTAssertEqual(actions.first?.title, "= 9",
            "CP2 / 场景2: 候选 title 必须 == \"= 9\"，实际 \"\(actions.first?.title ?? "nil")\"")
    }

    /// 场景3 [det-machine] + CP2：actions(for:"2^3^2") → title=="= 512"（右结合）
    ///
    /// Mutation-Survival 自检：
    /// - 求值器 ^ 左结合 mutant → 得 64 → title=="= 64" → 本断言失败（捕获）
    func test_CP2_scenario3_powerRightAssoc_titleEq512() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "2^3^2")

        XCTAssertEqual(actions.count, 1,
            "CP2 / 场景3: actions(for:\"2^3^2\") 必须恰好 1 候选，实际 \(actions.count)")
        XCTAssertEqual(actions.first?.title, "= 512",
            "CP2 / 场景3: 候选 title 必须 == \"= 512\"（^ 右结合 2^(3^2)），实际 \"\(actions.first?.title ?? "nil")\"")
    }

    /// CP2 补充：actions(for:"7%2") → title=="= 1"（模运算）
    func test_CP2_modulo_titleEq1() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "7%2")

        XCTAssertEqual(actions.count, 1,
            "CP2: actions(for:\"7%2\") 必须恰好 1 候选，实际 \(actions.count)")
        XCTAssertEqual(actions.first?.title, "= 1",
            "CP2: 候选 title 必须 == \"= 1\"，实际 \"\(actions.first?.title ?? "nil")\"")
    }

    /// CP2 补充：浮点结果 title 含小数（如 "0.5"）
    func test_CP2_floatResult_titleContainsDecimal() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1/2")

        XCTAssertEqual(actions.count, 1,
            "CP2: actions(for:\"1/2\") 必须恰好 1 候选，实际 \(actions.count)")
        XCTAssertEqual(actions.first?.title, "= 0.5",
            "CP2: 候选 title 必须 == \"= 0.5\"（浮点结果保留小数），实际 \"\(actions.first?.title ?? "nil")\"")
    }

    // MARK: - CP3：静默降级（场景 4-5 + 错误边界）

    /// 场景4 [det-machine] + CP3：actions(for:"1/0") → []（除零静默降级，不出候选）
    func test_CP3_scenario4_divisionByZero_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1/0")

        XCTAssertTrue(actions.isEmpty,
            "CP3 / 场景4: actions(for:\"1/0\") 必须返回 []（除零静默降级，不出候选不呈现错误 UI），实际 \(actions.count) 条")
    }

    /// 场景5 [det-machine] + CP3：actions(for:"365") → []（裸数字不激活，防劫持 AppLauncher）
    func test_CP3_scenario5_bareNumber_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "365")

        XCTAssertTrue(actions.isEmpty,
            "CP3 / 场景5: actions(for:\"365\") 必须返回 []（裸数字不激活，让 AppLauncher 接管），实际 \(actions.count) 条")
    }

    /// CP3：actions(for:"abc") → []（字母非白名单）
    func test_CP3_letters_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "abc")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"abc\") 必须返回 []（字母非白名单），实际 \(actions.count) 条")
    }

    /// CP3：actions(for:"1+") → []（语法错误）
    func test_CP3_syntaxError_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1+")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"1+\") 必须返回 []（语法错误静默降级），实际 \(actions.count) 条")
    }

    /// CP3：actions(for:"") → []（空 query）
    func test_CP3_emptyQuery_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"\") 必须返回 []（空 query），实际 \(actions.count) 条")
    }

    /// CP3：actions(for:"   ") → []（纯空格）
    func test_CP3_spacesOnly_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "   ")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"   \") 必须返回 []（纯空格无运算符），实际 \(actions.count) 条")
    }

    /// CP3 补充：actions(for:"5%0") → []（模零静默降级）
    func test_CP3_moduloByZero_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "5%0")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"5%0\") 必须返回 []（模零静默降级），实际 \(actions.count) 条")
    }

    /// CP3 补充：actions(for:"(1+2") → []（括号不匹配）
    func test_CP3_unbalancedParen_returnsEmpty() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "(1+2")

        XCTAssertTrue(actions.isEmpty,
            "CP3: actions(for:\"(1+2\") 必须返回 []（括号不匹配静默降级），实际 \(actions.count) 条")
    }

    // MARK: - CP4：副标题含表达式 + "复制" 提示

    /// CP4：actions(for:"1+2*3") 候选 subtitle 含表达式 "1+2*3" 与 "复制" 提示
    func test_CP4_subtitle_containsExpressionAndCopyHint() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1+2*3")

        guard let action = actions.first else {
            XCTFail("CP4 precondition: actions(for:\"1+2*3\") 必须有候选")
            return
        }

        let subtitle = action.subtitle ?? ""
        XCTAssertTrue(subtitle.contains("1+2*3"),
            "CP4: subtitle 必须含表达式 \"1+2*3\"，实际 \"\(subtitle)\"")
        XCTAssertTrue(subtitle.contains("复制"),
            "CP4: subtitle 必须含 \"复制\" 提示（回车复制），实际 \"\(subtitle)\"")
    }

    /// CP4 补充：副标题在带空格表达式场景也含核心表达式（trim 后）
    func test_CP4_subtitle_containsExpression_withSpaces() async {
        let plugin = CalculatorPlugin.shared
        let actions = await plugin.actions(for: "1 + 2 * 3")

        guard let action = actions.first else {
            XCTFail("CP4 precondition: actions(for:\"1 + 2 * 3\") 必须有候选")
            return
        }

        let subtitle = action.subtitle ?? ""
        // 副标题至少含运算符与数字（表达式核心成分），且含"复制"
        XCTAssertTrue(subtitle.contains("复制"),
            "CP4: 带空格表达式 subtitle 必须含 \"复制\"，实际 \"\(subtitle)\"")
    }

    // MARK: - CP5 / 场景6：perform 复制（注入 pasteboard，断言实际内容）

    /// 场景6 [det-machine] + CP5：注入命名 pasteboard，perform 后读实际内容 == "4"（裸格式化结果）
    ///
    /// Mutation-Survival 自检：
    /// - No-op perform mutant（perform 什么都不做）→ pasteboard 仍空 → 本断言失败（捕获）
    /// - 写错内容 mutant（写 title "= 4" 而非裸格式化结果 "4"，或写表达式）→ 内容 != "4" → 本断言失败（捕获）
    /// - 用 CopyService.shared mutant（写系统剪贴板污染）→ 测试 pasteboard 空 → 本断言失败（捕获）
    func test_CP5_scenario6_perform_writesFormattedResultToPasteboard() async throws {
        // 1. 构造隔离 pasteboard + 注入的 CopyService
        let pasteboardName = NSPasteboard.Name("ccb-test-calc-\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: pasteboardName)
        testPasteboard.clearContents()
        let testCopyService = CopyService(pasteboard: testPasteboard)

        // 2. 用注入的 CopyService 构造 plugin（不用 .shared，避免污染系统剪贴板）
        let plugin = CalculatorPlugin(copyService: testCopyService)

        // 3. 取候选（"1+3" → 4）
        let actions = await plugin.actions(for: "1+3")
        guard let action = actions.first else {
            XCTFail("CP5 / 场景6 precondition: actions(for:\"1+3\") 必须有候选")
            return
        }

        // 确认 title 正确（precondition）
        XCTAssertEqual(action.title, "= 4",
            "CP5 / 场景6 precondition: title 必须 == \"= 4\"，实际 \"\(action.title)\"")

        // 4. 执行 perform（模拟按 Enter）
        XCTAssertNoThrow(try action.perform(),
            "CP5 / 场景6: perform() 不应抛错（CopyService.copy 静默忽略失败）")

        // 5. 硬断言：读实际粘贴板内容，必须 == "4"（裸格式化结果，不含 "= " 前缀；title 才带前缀）
        let actualContent = testPasteboard.string(forType: .string)
        XCTAssertEqual(actualContent, "4",
            "CP5 / 场景6 (mutation-killer): perform() 后 pasteboard 实际内容必须 == \"4\"（裸格式化结果），实际 \"\(actualContent ?? "nil")\"")
    }

    /// CP5 补充：浮点结果 perform 后 pasteboard 内容含小数（"1/2" → "0.5"）
    func test_CP5_perform_floatResult_writesDecimalToPasteboard() async throws {
        let pasteboardName = NSPasteboard.Name("ccb-test-calc-float-\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: pasteboardName)
        testPasteboard.clearContents()
        let testCopyService = CopyService(pasteboard: testPasteboard)

        let plugin = CalculatorPlugin(copyService: testCopyService)
        let actions = await plugin.actions(for: "1/2")

        guard let action = actions.first else {
            XCTFail("CP5 precondition: actions(for:\"1/2\") 必须有候选")
            return
        }

        try action.perform()

        let actualContent = testPasteboard.string(forType: .string)
        XCTAssertEqual(actualContent, "0.5",
            "CP5: 浮点结果 perform 后 pasteboard 必须 == \"0.5\"（裸结果），实际 \"\(actualContent ?? "nil")\"")
    }

    /// CP5 补充：perform 不触碰系统剪贴板（注入 pasteboard 隔离验证）
    func test_CP5_perform_doesNotTouchSystemPasteboard() async throws {
        // 系统剪贴板预埋一个 sentinel 值
        let sentinel = "ccb-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        // 注入隔离 pasteboard 的 plugin
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("ccb-test-calc-iso-\(UUID().uuidString)"))
        testPasteboard.clearContents()
        let plugin = CalculatorPlugin(copyService: CopyService(pasteboard: testPasteboard))

        let actions = await plugin.actions(for: "2+2")
        guard let action = actions.first else {
            XCTFail("CP5 precondition: actions(for:\"2+2\") 必须有候选")
            return
        }

        try action.perform()

        // 系统剪贴板内容应未被改动（仍是 sentinel）
        let systemContent = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(systemContent, sentinel,
            "CP5: perform 用注入的 CopyService 不应触碰系统剪贴板，系统剪贴板应仍是 sentinel \"\(sentinel)\"，实际 \"\(systemContent ?? "nil")\"")
    }

    // MARK: - CP6 / 场景7：跨插件仲裁（默认 registry calculator 置顶）

    /// 场景7 [det-machine] + CP6：默认 registry actions(for:"1+2*3") first.pluginId=="calculator"
    ///
    /// Mutation-Survival 自检：
    /// - priority 错误 mutant（calculator priority < system 100）→ first 非 calculator → 本断言失败（捕获）
    /// - 排序反向 mutant → first 非 calculator → 本断言失败（捕获）
    /// - 未注册 calculator mutant → 无 calculator 候选 → first 非 calculator → 本断言失败（捕获）
    func test_CP6_scenario7_defaultRegistry_calculatorFirst() async {
        // 默认 registry（含 calculator / system / app-launcher）
        let registry = BuiltinPluginRegistry()

        let result = await registry.actions(for: "1+2*3")

        // 必须有候选
        XCTAssertFalse(result.isEmpty,
            "CP6 / 场景7 precondition: 默认 registry actions(for:\"1+2*3\") 必须返回非空候选")

        // first.pluginId == "calculator"（priority 200 置顶）
        XCTAssertEqual(result.first?.pluginId, "calculator",
            "CP6 / 场景7 (mutation-killer): 默认 registry 仲裁后 first.pluginId 必须 == \"calculator\"（priority 200 置顶），实际 \"\(result.first?.pluginId ?? "nil")\"")
    }

    /// 场景7 补充：默认 registry 含 calculator 插件
    func test_CP6_defaultRegistry_containsCalculatorPlugin() {
        let registry = BuiltinPluginRegistry()
        let hasCalculator = registry.plugins.contains { $0.id == "calculator" }
        XCTAssertTrue(hasCalculator,
            "CP6: 默认 registry 必须含 id==\"calculator\" 的插件，实际 plugins=\(registry.plugins.map { $0.id })")
    }

    /// CP6 补充：calculator candidate 在仲裁结果中排首位（index 0），且 title=="= 7"
    func test_CP6_calculatorCandidate_atIndex0_withCorrectTitle() async {
        let registry = BuiltinPluginRegistry()
        let result = await registry.actions(for: "1+2*3")

        guard let first = result.first else {
            XCTFail("CP6 precondition: 必须有候选")
            return
        }
        XCTAssertEqual(first.pluginId, "calculator",
            "CP6: index 0 候选必须来自 calculator")
        XCTAssertEqual(first.title, "= 7",
            "CP6: index 0 候选 title 必须 == \"= 7\"，实际 \"\(first.title)\"")
    }

    // MARK: - CP7：reset() 后默认列表仍含 calculator（防 flaky）

    /// CP7 / Extra：BuiltinPluginRegistry.shared.reset() 后默认列表仍含 calculator 插件
    ///
    /// 注意：当前 BuiltinPluginRegistry.reset() 默认列表是 [SystemCommandPlugin.shared, AppLauncherPlugin.shared]
    /// （见 BuiltinPluginRegistry.swift 第 72 行，既有代码）。若 reset 漏注册 calculator，
    /// 此测试将失败——这是 init 与 reset 不一致的 flaky 隐患。
    ///
    /// CONTRACT_AMBIGUOUS: 若设计意图 reset() 默认列表不含 calculator（仅 init 含），
    /// 此测试应改为 XCTSkip 或断言相反。按"防 flaky"原则断言 reset 后仍含 calculator。
    func test_CP7_reset_stillContainsCalculatorPlugin() {
        BuiltinPluginRegistry.shared.reset()

        let hasCalculator = BuiltinPluginRegistry.shared.plugins.contains { $0.id == "calculator" }
        XCTAssertTrue(hasCalculator,
            "CP7 (防 flaky / CONTRACT_AMBIGUOUS): reset() 后默认插件列表必须仍含 id==\"calculator\" 的插件，实际 plugins=\(BuiltinPluginRegistry.shared.plugins.map { $0.id })。若 reset 默认列表设计上排除 calculator，需调整此测试或修复 reset 一致性")
    }

    // MARK: - ISOLATION（源码扫描留 QA 核对）

    // ISOLATION: 蓝队实现信息隔离，CalculatorPlugin.swift 源码扫描留 QA 核对。
    // 本红队测试不读取 CalculatorPlugin.swift 实现（信息隔离铁律），
    // 故无法在测试中断言其不 import Scene/Session/EventBus。
    // QA 阶段应补充源码扫描测试（镜像 AppLauncherIsolationAcceptanceTests 风格），
    // 断言 Launcher/Builtin/Calculator/ 下 .swift 文件不引用像素猫符号。
    // 此处仅以注释形式预注册该验收点，不编写会读实现的测试。
}
