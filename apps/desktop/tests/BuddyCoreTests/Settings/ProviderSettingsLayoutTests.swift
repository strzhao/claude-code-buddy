import XCTest
import AppKit
@testable import BuddyCore

// MARK: - ProviderSettingsLayoutTests
//
// 蓝队自测：AI 配置布局优化（autopilot 2026-07-13）。
//
// 覆盖契约（state.md ## 契约规约）：
//   C-AI-ONE-CONTROL-PER-ROW   每行单一主输入 control（model 行=单 modelField；
//                              baseURL 行=单 baseURLField；关闭思考=独立 toggle row；
//                              连接测试=独立 action row）
//   C-AX-STABLE                settings.ai.formPanel 不变
//
// 测试驱动：in-process UI（实例化 VC + 遍历 view 树断言行 Y 轴不重叠）。
// 只跑本测试类：make test-only FILTER=ProviderSettingsLayoutTests

@MainActor
final class ProviderSettingsLayoutTests: XCTestCase {

    // MARK: - C-AI-ONE-CONTROL-PER-ROW：SettingsFormRow 行容器 Y 轴不重叠

    func test_aiFormRows_yAxis_nonOverlapping() {
        let vc = ProviderSettingsViewController()
        _ = vc.view  // 触发 loadView
        vc.view.layoutSubtreeIfNeeded()

        // 找 formPanel（AX id settings.ai.formPanel）
        guard let formPanel = findView(byAccessibilityId: "settings.ai.formPanel", in: vc.view) else {
            XCTFail("应找到 settings.ai.formPanel")
            return
        }

        // 收集 formPanel 子树所有 SettingsFormRow 行容器
        let formRows = collectViews(ofType: SettingsFormRow.self, in: formPanel)
        XCTAssertGreaterThanOrEqual(formRows.count, 4,
                                    "AI 表单应至少 4 个 SettingsFormRow（provider/kind/model/baseURL/apiKey/test），实际：\(formRows.count)")

        // 两两 Y 轴不重叠（C-AI-ONE-CONTROL-PER-ROW）。
        // 注：行容器 frame 在 superview 坐标系，先统一转换到 formPanel 坐标系再比。
        let boundsInFormPanel = formRows.map { row -> NSRect in
            row.convert(row.bounds, to: formPanel)
        }
        for i in 0..<boundsInFormPanel.count {
            for j in (i+1)..<boundsInFormPanel.count {
                let a = boundsInFormPanel[i]
                let b = boundsInFormPanel[j]
                let nonOverlapping = a.maxY <= b.minY || b.maxY <= a.minY
                XCTAssertTrue(nonOverlapping,
                             "C-AI-ONE-CONTROL-PER-ROW: 行 \(i) 与行 \(j) Y 轴不应重叠（a=\(a) b=\(b)）")
            }
        }
    }

    // MARK: - model 行单一 control（modelField 不再与 noThinking 水平挤压）

    func test_modelRow_singleControl_modelFieldNotInHorizontalStack() {
        let vc = ProviderSettingsViewController()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        guard let formPanel = findView(byAccessibilityId: "settings.ai.formPanel", in: vc.view) else {
            XCTFail("应找到 settings.ai.formPanel")
            return
        }
        let formRows = collectViews(ofType: SettingsFormRow.self, in: formPanel)
        // 找 model 行（title 含「模型」）
        guard let modelRow = formRows.first(where: { row in
            collectStaticTexts(in: row).contains(where: { $0.contains("模型") })
        }) else {
            XCTFail("应找到「模型」行")
            return
        }
        // model 行 controlContainer 应直接含 modelField（NSTextField），不是水平 NSStackView 包多个
        let stacksInControl = modelRow.subviews
            .flatMap { $0.subviews }
            .filter { $0 is NSStackView }
        // model 行 control 区域不应含 NSStackView（关闭思考已拆出）
        XCTAssertTrue(stacksInControl.isEmpty,
                      "C-AI-ONE-CONTROL-PER-ROW: 模型行 control 不应含水平 NSStackView（关闭思考已拆出独立行）")
    }

    // MARK: - baseURL 行单一 control（baseURLField 不再与 testButton 水平挤压）

    func test_baseURLRow_singleControl_noTestButtonInline() {
        let vc = ProviderSettingsViewController()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        guard let formPanel = findView(byAccessibilityId: "settings.ai.formPanel", in: vc.view) else {
            XCTFail("应找到 settings.ai.formPanel")
            return
        }
        let formRows = collectViews(ofType: SettingsFormRow.self, in: formPanel)
        // 找 API 地址行（title 含「API 地址」）
        guard let baseURLRow = formRows.first(where: { row in
            collectStaticTexts(in: row).contains(where: { $0.contains("API 地址") })
        }) else {
            XCTFail("应找到「API 地址」行")
            return
        }
        // baseURL 行不应含 NSButton（testButton 已拆出独立行）
        let buttonsInRow = collectViews(ofType: NSButton.self, in: baseURLRow)
        XCTAssertTrue(buttonsInRow.isEmpty,
                      "C-AI-ONE-CONTROL-PER-ROW: API 地址行不应含 NSButton（测试连接已拆出独立行），实际：\(buttonsInRow)")
    }

    // MARK: - 连接测试独立行存在

    func test_connectionTestRow_exists() {
        let vc = ProviderSettingsViewController()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        guard let formPanel = findView(byAccessibilityId: "settings.ai.formPanel", in: vc.view) else {
            XCTFail("应找到 settings.ai.formPanel")
            return
        }
        let formRows = collectViews(ofType: SettingsFormRow.self, in: formPanel)
        // 找连接测试行（title 含「连接测试」）
        let testRow = formRows.first(where: { row in
            collectStaticTexts(in: row).contains(where: { $0.contains("连接测试") })
        })
        XCTAssertNotNil(testRow, "应有独立的「连接测试」行")
        // 该行应含 NSButton（测试连接按钮）
        if let testRow {
            let buttons = collectViews(ofType: NSButton.self, in: testRow)
            XCTAssertGreaterThanOrEqual(buttons.count, 1, "连接测试行应含至少 1 个 NSButton")
        }
    }

    // MARK: - 私有 helpers

    private func findView(byAccessibilityId id: String, in view: NSView) -> NSView? {
        if (view.accessibilityIdentifier() ?? "") == id { return view }
        for sub in view.subviews {
            if let found = findView(byAccessibilityId: id, in: sub) { return found }
        }
        return nil
    }

    private func collectViews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: collectViews(ofType: type, in: sub))
        }
        return result
    }

    private func collectStaticTexts(in view: NSView) -> [String] {
        var texts: [String] = []
        if let tf = view as? NSTextField {
            texts.append(tf.stringValue)
        }
        for sub in view.subviews {
            texts.append(contentsOf: collectStaticTexts(in: sub))
        }
        return texts
    }
}
