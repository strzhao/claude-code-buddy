import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - Helpers

private extension CatSpriteTabNameTests {

    /// 在 node.children 中找到 fontSize=12 且 zPosition=10 的 SKLabelNode（主 tab name 节点）
    func findTabNameNode(in cat: CatSprite) -> SKLabelNode? {
        cat.node.children.compactMap { $0 as? SKLabelNode }.first {
            $0.fontSize == CatConstants.Visual.tabLabelFontSize && $0.zPosition == 10
        }
    }

    /// 构造已配置的 CatSprite（idle 状态）
    func makeCat(label: String = "my-project") -> CatSprite {
        let cat = CatSprite(sessionId: "test-\(label)")
        cat.configure(color: .sky, labelText: label)
        return cat
    }

    /// 切换到 permissionRequest：先从 idle 切到 thinking，再切到 permissionRequest，
    /// 以确保不会因 guard newState != currentState 短路。
    /// 实际上 idle → permissionRequest 之间没有 guard 阻断（初始状态是 idle，
    /// permissionRequest 不等于 idle），可直接切换。
    func switchToPermissionRequest(_ cat: CatSprite, toolDescription: String = "Run command") {
        cat.switchState(to: .permissionRequest, toolDescription: toolDescription)
    }
}

// MARK: - CatSpriteTabNameTests

final class CatSpriteTabNameTests: XCTestCase {

    // MARK: - 场景 1：permissionRequest 状态下 tab name 可见

    func testTabNameVisibleInPermissionRequestState() {
        let cat = makeCat(label: "my-project")

        switchToPermissionRequest(cat)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertNotNil(tabNode, "permissionRequest 状态下应存在 tab name 节点")
        XCTAssertFalse(tabNode!.isHidden, "permissionRequest 状态下 tab name 节点应可见")
    }

    func testTabNameTextInPermissionRequestState() {
        let cat = makeCat(label: "my-project")

        switchToPermissionRequest(cat)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertEqual(tabNode?.text, "my-project", "tab name 文本应与 configure 设置的 labelText 一致")
    }

    // MARK: - 场景 2：其他状态下 tab name 隐藏

    func testTabNameHiddenInIdleState() {
        // idle 是初始状态，configure 之后 tabNameNode 默认 isHidden=true
        let cat = makeCat(label: "my-project")

        let tabNode = findTabNameNode(in: cat)
        XCTAssertNotNil(tabNode, "configure 后应存在 tab name 节点")
        XCTAssertTrue(tabNode!.isHidden, "idle 状态下 tab name 节点应隐藏")
    }

    func testTabNameHiddenInThinkingState() {
        let cat = makeCat(label: "my-project")
        // idle → thinking（无 guard 阻断）
        cat.switchState(to: .thinking)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertNotNil(tabNode, "configure 后应存在 tab name 节点")
        XCTAssertTrue(tabNode!.isHidden, "thinking 状态下 tab name 节点应隐藏")
    }

    func testTabNameHiddenInToolUseState() {
        let cat = makeCat(label: "my-project")
        // idle → toolUse
        cat.switchState(to: .toolUse)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertNotNil(tabNode, "configure 后应存在 tab name 节点")
        XCTAssertTrue(tabNode!.isHidden, "toolUse 状态下 tab name 节点应隐藏")
    }

    // MARK: - 场景 3：从 permissionRequest 切换到其他状态后 tab name 隐藏

    func testTabNameHiddenAfterLeavingPermissionRequest() {
        let cat = makeCat(label: "my-project")

        // idle → permissionRequest → thinking
        switchToPermissionRequest(cat)
        // 验证当前可见（先验前置条件）
        let tabNodeBefore = findTabNameNode(in: cat)
        XCTAssertFalse(tabNodeBefore?.isHidden ?? true,
                       "切换前 permissionRequest 状态下 tab name 应可见")

        // permissionRequest → thinking（有 jump 过渡动画，但 hideLabel() 在 switchState 开头同步执行）
        cat.switchState(to: .thinking)

        let tabNodeAfter = findTabNameNode(in: cat)
        XCTAssertTrue(tabNodeAfter?.isHidden ?? false,
                      "离开 permissionRequest 后 tab name 节点应隐藏")
    }

    func testTabNameHiddenAfterPermissionRequestToIdle() {
        let cat = makeCat(label: "my-project")

        // idle → permissionRequest → thinking → idle（避免 permissionRequest→idle 的 jump 动画干扰断言）
        switchToPermissionRequest(cat)
        cat.switchState(to: .thinking)
        cat.switchState(to: .idle)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertTrue(tabNode?.isHidden ?? false,
                      "回到 idle 状态后 tab name 节点应隐藏")
    }

    // MARK: - 场景 4：updateLabel 同步更新 tab name 文本

    func testUpdateLabelSyncsTabNameText() {
        let cat = makeCat(label: "old-name")

        cat.updateLabel("new-name")
        switchToPermissionRequest(cat)

        let tabNode = findTabNameNode(in: cat)
        XCTAssertEqual(tabNode?.text, "new-name",
                       "updateLabel 后 tab name 文本应更新为新值")
    }

    func testUpdateLabelBeforeConfigureHasNoEffect() {
        // configure 之前调用 updateLabel 不应崩溃（tabNameNode 为 nil）
        let cat = CatSprite(sessionId: "bare")
        cat.updateLabel("anything") // 不应崩溃
        XCTAssertNil(findTabNameNode(in: cat),
                     "未 configure 时不应存在 tab name 节点")
    }

    // MARK: - 节点结构完整性

    func testTabNameNodeHasFontSize9() {
        let cat = makeCat(label: "test")
        let tabNode = findTabNameNode(in: cat)
        XCTAssertEqual(tabNode?.fontSize, CatConstants.Visual.tabLabelFontSize, "tab name 节点的 fontSize 应匹配常量")
    }

    func testTabNameNodeHasZPosition10() {
        let cat = makeCat(label: "test")
        let tabNode = findTabNameNode(in: cat)
        XCTAssertEqual(tabNode?.zPosition, 10, "tab name 节点的 zPosition 应为 10")
    }

    func testTabNameShadowNodeExists() {
        let cat = makeCat(label: "test")
        // shadow node: fontSize=tabLabelFontSize, zPosition=9
        let shadowNode = cat.node.children
            .compactMap { $0 as? SKLabelNode }
            .first { $0.fontSize == CatConstants.Visual.tabLabelFontSize && $0.zPosition == 9 }
        XCTAssertNotNil(shadowNode, "configure 后应存在 tab name shadow 节点")
    }

    func testTabNameNodeIsDistinctFromMainLabel() {
        // 主 label 节点 fontSize=labelFontSize，tab name 节点 fontSize=tabLabelFontSize，两者应独立存在
        let cat = makeCat(label: "test")
        let mainLabel = cat.node.children
            .compactMap { $0 as? SKLabelNode }
            .first { $0.fontSize == CatConstants.Visual.labelFontSize && $0.zPosition == 10 }
        let tabNode = findTabNameNode(in: cat)

        XCTAssertNotNil(mainLabel, "应存在主 label 节点（fontSize=labelFontSize, zPosition=10）")
        XCTAssertNotNil(tabNode, "应存在 tab name 节点（fontSize=tabLabelFontSize, zPosition=10）")
        XCTAssertFalse(mainLabel === tabNode,
                       "主 label 节点与 tab name 节点应为不同对象")
    }
}
