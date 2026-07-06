import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：AI 配置 JSON 面板"看不到内容"修复（2026-07-02）

/// 黑盒验收测试：基于设计文档描述的根因 + 修复方案 + 数据层契约，逐项验证。
/// 本文件**不读取**蓝队 `ProviderSettingsViewController.swift` 的实现体（仅在调研阶段读取过
/// 属性/方法签名区以确定可访问性），只对设计文档中承诺的"外部可观测行为"下断言。
///
/// 设计权威源（唯一真相）：
/// - 根因：`tabDidChange` 切 JSON tab 时，`syncToJSON()` 在 `jsonPanel.isHidden = false`
///   **之前**执行；NSScrollView 在 isHidden=true 时不计算 textContainer 布局，
///   set string 后 containerSize 未刷新，切回可见 AppKit 不自动补 layout → 视觉空白。
/// - 修复 1：`tabDidChange` 切 JSON 分支先 `jsonPanel.isHidden = false` 再 `syncToJSON()`。
/// - 修复 2：`syncToJSON` 末尾 set string 后调
///   `jsonTextView.scrollRangeToVisible(...)` + `jsonScrollView.needsLayout = true` 强制刷新布局。
/// - 修复 3：`syncToJSON`/`tabDidChange` 用 `BuddyLogger.shared`（subsystem: "settings"）
///   记录 `editingProviderID / panelIsHidden / providersCount / jsonLength / providerId`。
///
/// 数据层契约（可测，本文件核心断言对象）：
/// - `config.providers` 非空且 `editingProviderID` 命中 → `syncToJSON` 后
///   `jsonTextView.string` 是合法 JSON，含 `kind/model/keyRef` 字段。
/// - `editingProviderID` 为 nil 或 provider 不存在 → `jsonTextView.string` == ""。
/// - 切 JSON tab 后 string 非空且 panel 可见（无 isHidden 祖先链）。
///
/// 验收场景（预注册谓词）：
/// - P1：切到 JSON tab 后 `jsonTextView.string.count > 0` 且面板可见（非 isHidden 链）。
/// - P2：`buddy log show --subsystem settings` 含 `syncToJSON` 调用记录，meta 含 `providerId`。
///        单元层等价断言：`BuddyLogger.configureForTesting` 重定向到临时目录后直接读 JSONL 校验。
/// - P3：表单→JSON→表单→JSON 来回切，两次 JSON 态 string 一致。
///
/// ⚠️ 可测性说明：`ProviderSettingsViewController` 全部业务成员为 `private`，无构造期注入点
/// （`loadConfig()` 固定读 `LauncherConfig.load()` → `LauncherConstants.launcherConfigPath`，
/// 即真实 `~/.buddy/launcher.json`）。本文件复用既有测试先例
/// （`LauncherManagerTests.test_submit_whenNotConfigured_returnsProviderNotConfiguredError`）
/// 的"备份→写入 fixture→恢复"手法操作真实配置文件路径，达成确定性注入，测试结束严格还原
/// 开发者机器上的原始配置，不污染真实环境。
/// 触发 tab 切换走 `NSSegmentedControl.target.perform(action:with:)`——Objective-C 运行时
/// selector 派发不受 Swift `private`/`@objc private` 访问控制限制，是既有测试文件
/// （`SettingsSidebarAcceptanceTests` / `SettingsPersistenceTests`）验证过的合法手法。
///
/// P2 的「日志出现在 `buddy log show --subsystem settings` CLI 输出」这一 CLI 展示层断言
/// 留 QA 真机验证（构建 app → 触发 tab 切换 → 执行 `buddy log show --subsystem settings`
/// 人工核对 `syncToJSON` 字样 + `providerId` meta 字段），单元层无法启动真实 app 进程执行 CLI。
@MainActor
final class ProviderSettingsAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 递归找第一个指定类型的子视图。
    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    /// 强制 view 加载。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 视图沿 superview 链是否"有效可见"（自身及所有祖先 isHidden 均为 false）。
    /// 用于替代 UIKit 的 isHiddenOrHasHiddenAncestor（AppKit 无此 API）。
    private func isEffectivelyVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return false }
            current = v.superview
        }
        return true
    }

    /// 触发 NSSegmentedControl 的 target/action（模拟用户点击分段控件）。
    /// Objective-C 运行时 selector 派发，绕过 Swift `@objc private` 访问控制——
    /// 与既有测试（SettingsSidebarAcceptanceTests.flipSwitch）同款手法。
    private func fireAction(_ control: NSSegmentedControl) {
        guard let target = control.target, let action = control.action else {
            XCTFail("NSSegmentedControl 必须绑定 target/action 才能触发 tab 切换")
            return
        }
        _ = target.perform(action, with: control)
    }

    /// 备份真实 `~/.buddy/launcher.json`（若存在）→ 写入 fixture config → 执行 body → 还原。
    /// 复用 LauncherManagerTests 已验证过的"备份/还原真实配置文件"手法，达成确定性注入
    /// （ProviderSettingsViewController 无构造期依赖注入点，只能通过其固定读取路径注入）。
    private func withRealLauncherConfig(_ config: LauncherConfig, _ body: () throws -> Void) throws {
        let realPath = LauncherConstants.launcherConfigPath
        let existedBefore = FileManager.default.fileExists(atPath: realPath.path)
        let backupPath = LauncherConstants.buddyDir.appendingPathComponent(
            "launcher.json.test-bak-provideracceptance-\(UUID().uuidString)")

        if existedBefore {
            try? FileManager.default.removeItem(at: backupPath)
            try? FileManager.default.copyItem(at: realPath, to: backupPath)
            try? FileManager.default.removeItem(at: realPath)
        }
        defer {
            try? FileManager.default.removeItem(at: realPath)
            if existedBefore {
                try? FileManager.default.moveItem(at: backupPath, to: realPath)
            }
        }

        try config.save()
        try body()
    }

    // MARK: - P1 + 数据层契约（正例）：provider 命中 → JSON 非空 + 合法 + 含关键字段 + 面板可见

    /// P1 [visual-residue]: 切到 JSON tab 后 jsonTextView.string 非空、面板可见（无 isHidden 祖先）。
    /// 数据层契约：string 必须是合法 JSON，含 kind/model/keyRef 字段。
    /// 杀死"JSON tab 切换后内容仍为空/面板仍隐藏"的回归（本任务的修复目标）。
    func test_P1_jsonTab_showsNonEmptyValidJSON_whenProviderConfigured() throws {
        let provider = ProviderConfig(
            kind: "anthropic",
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-5",
            keyRef: "acc-test.apiKey"
        )
        let cfg = LauncherConfig(activeProvider: "acc-test", providers: ["acc-test": provider])

        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            forceLoadView(vc)

            guard let seg = findFirst(NSSegmentedControl.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含表单/JSON NSSegmentedControl")
            }
            guard let jsonTV = findFirst(NSTextView.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含 JSON 编辑 NSTextView")
            }

            // 切到 JSON tab（segment 1）
            seg.selectedSegment = 1
            fireAction(seg)

            // P1：非空 + 面板可见
            XCTAssertGreaterThan(jsonTV.string.count, 0,
                                 "P1 违反：切到 JSON tab 后 jsonTextView.string 必须非空（这正是要修复的'看不到内容'bug）")
            XCTAssertTrue(isEffectivelyVisible(jsonTV),
                          "P1 违反：切到 JSON tab 后 JSON 面板必须可见（无 isHidden 祖先链）")
            // width 机制断言（防回归）：jsonTextView 作为 NSScrollView.documentView，必须配置
            // autoresizing width + widthTracksTextView，否则 scrollView 不传宽度 → textView width=0
            // → 内容不可见（真机 AX 实测修复前 width=0、修复后 width=508）。
            // 测试环境无窗口布局，bounds.width 恒为 0，故断言"机制配置"而非"布局效果"。
            XCTAssertTrue(jsonTV.autoresizingMask.contains(.width),
                          "P1 违反：jsonTextView.autoresizingMask 必须含 .width（documentView 宽度跟随 scrollView）")
            XCTAssertEqual(jsonTV.textContainer?.widthTracksTextView, true,
                           "P1 违反：textContainer.widthTracksTextView 必须为 true（container 宽度跟随 textView）")

            // 数据层契约：合法 JSON + 含 kind/model/keyRef
            guard let data = jsonTV.string.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return XCTFail("数据契约违反：jsonTextView.string 必须是合法 JSON，实际: \(jsonTV.string)")
            }
            XCTAssertEqual(json["kind"] as? String, "anthropic",
                           "数据契约：JSON 必须含 kind 字段且与 provider 一致")
            XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-5",
                           "数据契约：JSON 必须含 model 字段且与 provider 一致")
            XCTAssertEqual(json["keyRef"] as? String, "acc-test.apiKey",
                           "数据契约：JSON 必须含 keyRef 字段且与 provider 一致")
        }
    }

    // MARK: - 数据层契约（反例）：editingProviderID 为 nil → JSON 为空串

    /// 数据层契约：`config.providers` 为空（未配置任何 provider）时，`editingProviderID` 始终为
    /// nil（`populateUI` 走 `clearProviderFields()` 分支，从不调用 `loadProvider(id:)`），
    /// 切到 JSON tab 后 `jsonTextView.string` 必须精确为空串。
    /// 杀死"无 provider 时仍拼出脏 JSON 占位"的回归。
    func test_dataContract_jsonTab_emptyString_whenNoProviderConfigured() throws {
        try withRealLauncherConfig(.empty) {
            let vc = ProviderSettingsViewController()
            forceLoadView(vc)

            guard let seg = findFirst(NSSegmentedControl.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含表单/JSON NSSegmentedControl")
            }
            guard let jsonTV = findFirst(NSTextView.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含 JSON 编辑 NSTextView")
            }

            seg.selectedSegment = 1
            fireAction(seg)

            XCTAssertEqual(jsonTV.string, "",
                           "数据契约违反：editingProviderID 为 nil 时 jsonTextView.string 必须精确为空串，"
                           + "实际: '\(jsonTV.string)'")
        }
    }

    // MARK: - P3：表单↔JSON 来回切换，两次 JSON 态 string 一致

    /// P3 [visual-residue]: 表单→JSON→表单→JSON 来回切，两次 JSON 态 jsonTextView.string 必须一致。
    /// 杀死"第二次切回 JSON 内容漂移/丢失"的回归（isSyncing 防递归 + 强制布局刷新协同正确性）。
    func test_P3_formJsonFormJson_roundTrip_stringConsistent() throws {
        let provider = ProviderConfig(
            kind: "openai-compatible",
            baseURL: "http://localhost:8000/v1",
            model: "qwen3-35b",
            keyRef: "acc-test2.apiKey",
            noThinking: true
        )
        let cfg = LauncherConfig(activeProvider: "acc-test2", providers: ["acc-test2": provider])

        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            forceLoadView(vc)

            guard let seg = findFirst(NSSegmentedControl.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含表单/JSON NSSegmentedControl")
            }
            guard let jsonTV = findFirst(NSTextView.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含 JSON 编辑 NSTextView")
            }

            // 第一次：表单 → JSON
            seg.selectedSegment = 1
            fireAction(seg)
            let jsonString1 = jsonTV.string
            XCTAssertGreaterThan(jsonString1.count, 0, "第一次切 JSON 应非空（P1 前提）")

            // JSON → 表单
            seg.selectedSegment = 0
            fireAction(seg)

            // 第二次：表单 → JSON
            seg.selectedSegment = 1
            fireAction(seg)
            let jsonString2 = jsonTV.string

            XCTAssertEqual(jsonString1, jsonString2,
                           "P3 违反：表单→JSON→表单→JSON 来回切，两次 JSON 态 string 必须一致，"
                           + "第一次: '\(jsonString1)'，第二次: '\(jsonString2)'")
            XCTAssertTrue(isEffectivelyVisible(jsonTV),
                          "P3 补充：第二次切回 JSON 面板仍必须可见")
        }
    }

    // MARK: - P2：可观测日志（BuddyLogger subsystem=settings 含 syncToJSON + providerId meta）

    /// P2 [可观测性]: 切到 JSON tab 触发 `syncToJSON`，`BuddyLogger`（subsystem: "settings"）
    /// 必须落盘至少一条 msg 含 "syncToJSON" 的记录，且其中至少一条 meta 含 `providerId` 字段。
    /// 单元层等价于 `buddy log show --subsystem settings` 的可观测性断言：
    /// 通过 `BuddyLogger.configureForTesting` 重定向到临时目录，绕开真实 `~/.buddy/logs/`，
    /// 直接读回落盘的 JSONL 断言 schema + 内容。CLI 展示层（`buddy log show` 命令本身的
    /// 过滤/格式化）留 QA 真机验证，见文件头部说明。
    func test_P2_syncToJSON_logsToSettingsSubsystem_withProviderIdMeta() throws {
        let provider = ProviderConfig(
            kind: "anthropic",
            baseURL: nil,
            model: "claude-sonnet-4-5",
            keyRef: "acc-log.apiKey"
        )
        let cfg = LauncherConfig(activeProvider: "acc-log", providers: ["acc-log": provider])

        let tmpDir = NSTemporaryDirectory() + "ProviderSettingsAcceptanceTests-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpDir)
            BuddyLogger.shared.resetForTesting()
        }

        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: tmpDir, level: .debug)

        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            forceLoadView(vc)

            guard let seg = findFirst(NSSegmentedControl.self, in: vc.view) else {
                return XCTFail("AI 配置页必须含表单/JSON NSSegmentedControl")
            }

            seg.selectedSegment = 1
            fireAction(seg)
        }

        BuddyLogger.shared._syncFlush()

        let logPath = "\(tmpDir)/buddy.jsonl"
        let content = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        XCTAssertFalse(content.isEmpty,
                       "P2 违反：切到 JSON tab 后 BuddyLogger 必须产生日志，实际日志文件为空/不存在: \(logPath)")

        let lines = content.split(separator: "\n").map(String.init)
        let parsedLines: [[String: Any]] = lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let settingsLines = parsedLines.filter { ($0["subsystem"] as? String) == "settings" }
        XCTAssertGreaterThanOrEqual(settingsLines.count, 1,
                                    "P2 违反：必须存在 subsystem=='settings' 的日志行，实际全部日志: \(lines)")

        let syncLines = settingsLines.filter { ($0["msg"] as? String)?.contains("syncToJSON") == true }
        XCTAssertGreaterThanOrEqual(syncLines.count, 1,
                                    "P2 违反：必须存在 msg 含 'syncToJSON' 的日志行（设计契约：syncToJSON 入口/出口打日志），"
                                    + "实际 settings 日志: \(settingsLines)")

        let hasProviderIdMeta = syncLines.contains { line in
            (line["meta"] as? [String: Any])?["providerId"] != nil
        }
        XCTAssertTrue(hasProviderIdMeta,
                      "P2 违反：syncToJSON 相关日志的 meta 必须含 'providerId' 字段，实际: \(syncLines)")
    }
}
