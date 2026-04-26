import XCTest
import SpriteKit
import SnapshotTesting
@testable import BuddyCore

// MARK: - CatSpriteSnapshotTests

class CatSpriteSnapshotTests: XCTestCase {

    private let sceneSize = CGSize(width: 200, height: 120)

    // SpriteKit GPU rendering is non-deterministic across environments (Metal pipeline,
    // font rendering, scale factor differ between local Retina Mac and headless CI runner).
    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    private let spriteStrategy: Snapshotting<NSImage, NSImage> = .image(precision: 0.90, perceptualPrecision: 0.95)

    // MARK: - Helper

    private func renderCat(
        sessionId: String,
        stateSetup: ((CatSprite) -> Void)? = nil
    ) -> NSImage? {
        snapshotSKScene(size: sceneSize) { scene in
            let cat = CatSprite(sessionId: sessionId)
            cat.configure(color: .sky, labelText: sessionId)
            scene.addChild(cat.containerNode)
            cat.containerNode.position = CGPoint(x: 100, y: 60)
            cat.enterScene(sceneSize: scene.size, activityBounds: 24...176)
            stateSetup?(cat)
        }
    }

    // MARK: - Tests

    func testCatIdle() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-idle") else {
            XCTFail("Failed to render idle scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }

    func testCatThinking() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-thinking", stateSetup: { cat in
            cat.stateMachine.enter(CatThinkingState.self)
        }) else {
            XCTFail("Failed to render thinking scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }

    func testCatToolUse() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-tooluse", stateSetup: { cat in
            cat.stateMachine.enter(CatToolUseState.self)
        }) else {
            XCTFail("Failed to render toolUse scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }

    func testCatPermissionRequest() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-permission", stateSetup: { cat in
            cat.stateMachine.enter(CatPermissionRequestState.self)
        }) else {
            XCTFail("Failed to render permissionRequest scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }

    func testCatEating() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-eating", stateSetup: { cat in
            cat.stateMachine.enter(CatEatingState.self)
        }) else {
            XCTFail("Failed to render eating scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }

    func testCatTaskComplete() throws {
        try XCTSkipIf(isCI, "SpriteKit snapshot tests skipped on CI (GPU rendering differs)")
        guard let image = renderCat(sessionId: "snap-taskcomplete", stateSetup: { cat in
            cat.stateMachine.enter(CatTaskCompleteState.self)
        }) else {
            XCTFail("Failed to render taskComplete scene")
            return
        }
        assertSnapshot(of: image, as: spriteStrategy)
    }
}
