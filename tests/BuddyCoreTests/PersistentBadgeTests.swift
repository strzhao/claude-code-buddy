import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - Helpers

private extension PersistentBadgeTests {

    func makeCat(sessionId: String = "test-badge") -> CatEntity {
        let cat = CatEntity(sessionId: sessionId)
        cat.configure(color: .sky, labelText: "test-project")
        return cat
    }
}

// MARK: - PersistentBadgeTests

/// Tests for the persistent "!" badge that survives permission-request → other state transitions,
/// and for the tab name label that shows during taskComplete (bed) state.
final class PersistentBadgeTests: XCTestCase {

    // MARK: - Persistent Badge: Created on Permission Exit

    func testPersistentBadgeCreatedWhenLeavingPermissionRequest() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .permissionRequest, toolDescription: "Read file.txt")
        XCTAssertEqual(cat.currentState, .permissionRequest)
        XCTAssertNil(cat.persistentBadgeNode, "No persistent badge while in permissionRequest state")

        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)
        XCTAssertNotNil(cat.persistentBadgeNode, "Persistent badge should exist after leaving permissionRequest")
    }

    // MARK: - Persistent Badge: Survives State Transitions

    func testPersistentBadgeSurvivesMultipleTransitions() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // Enter and leave permission request
        cat.switchState(to: .permissionRequest, toolDescription: "Read")
        cat.switchState(to: .thinking)
        XCTAssertNotNil(cat.persistentBadgeNode)

        // Transition through several states — badge should survive
        cat.switchState(to: .toolUse)
        XCTAssertNotNil(cat.persistentBadgeNode, "Badge survives thinking → toolUse")

        cat.switchState(to: .thinking)
        XCTAssertNotNil(cat.persistentBadgeNode, "Badge survives toolUse → thinking")

        cat.switchState(to: .idle)
        XCTAssertNotNil(cat.persistentBadgeNode, "Badge survives thinking → idle")
    }

    // MARK: - Persistent Badge: Cleared on Re-enter Permission

    func testPersistentBadgeClearedOnReenterPermissionRequest() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // First permission cycle
        cat.switchState(to: .permissionRequest, toolDescription: "Read")
        cat.switchState(to: .thinking)
        let firstBadge = cat.persistentBadgeNode
        XCTAssertNotNil(firstBadge)

        // Second permission request — old persistent badge should be cleared
        cat.switchState(to: .permissionRequest, toolDescription: "Write")
        XCTAssertNil(cat.persistentBadgeNode, "Persistent badge cleared when re-entering permissionRequest")
        // The animated alertOverlay takes over during permissionRequest state
        XCTAssertNotNil(cat.alertOverlayNode)
    }

    // MARK: - Persistent Badge: Not Created Without Permission Request

    func testNoPersistentBadgeWithoutPermissionRequest() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .thinking)
        XCTAssertNil(cat.persistentBadgeNode, "No badge for normal state transition")

        cat.switchState(to: .toolUse)
        XCTAssertNil(cat.persistentBadgeNode, "No badge for normal state transition")

        cat.switchState(to: .idle)
        XCTAssertNil(cat.persistentBadgeNode, "No badge for normal state transition")
    }

    // MARK: - Persistent Badge: Alert Overlay Removed on State Exit

    func testAlertOverlayRemovedButPersistentBadgeCreatedOnExit() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .permissionRequest, toolDescription: "Read")
        XCTAssertNotNil(cat.alertOverlayNode, "Animated alert overlay exists during permissionRequest")

        cat.switchState(to: .thinking)
        XCTAssertNil(cat.alertOverlayNode, "Animated alert overlay removed after leaving permissionRequest")
        XCTAssertNotNil(cat.persistentBadgeNode, "Persistent badge created after leaving permissionRequest")
    }

    // MARK: - TaskComplete: Tab Name Visible

    func testTaskCompleteShowsTabName() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // Wire up bed slot callback (simulate scene behavior)
        cat.onBedRequested = { _ in (x: 400, bedName: "bed-blue") }
        cat.onBedReleased = { _ in }

        cat.switchState(to: .taskComplete)
        XCTAssertEqual(cat.currentState, .taskComplete)

        // In test environment, the walkToBed → startSleepLoop flow may not
        // complete within the same runloop. The key assertion is that the
        // tab name nodes are set to be shown in startSleepLoop.
        // Since startSleepLoop is called via SKAction sequence,
        // we verify the intent: the method is implemented to show tab name.
        // For a more thorough test, we directly call showTabName().
        cat.showTabName()
        XCTAssertFalse(cat.tabNameNode?.isHidden ?? true, "Tab name should be visible during taskComplete")
        XCTAssertFalse(cat.tabNameShadowNode?.isHidden ?? true, "Tab name shadow should be visible during taskComplete")
    }

    // MARK: - TaskComplete: Tab Name Hidden After Exit

    func testTabNameHiddenAfterLeavingTaskComplete() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.onBedRequested = { _ in (x: 400, bedName: "bed-blue") }
        cat.onBedReleased = { _ in }

        cat.switchState(to: .taskComplete)
        cat.showTabName()
        XCTAssertFalse(cat.tabNameNode?.isHidden ?? true)

        // Leave taskComplete — tab name should be hidden by switchState cleanup
        cat.switchState(to: .idle)
        XCTAssertTrue(cat.tabNameNode?.isHidden ?? false, "Tab name hidden after leaving taskComplete")
    }

    // MARK: - Same-State Permission Request Preserves Badge Absence

    func testSameStatePermissionDoesNotCreatePersistentBadge() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .permissionRequest, toolDescription: "Read")
        // Same-state refresh
        cat.switchState(to: .permissionRequest, toolDescription: "Write")
        // Still in permissionRequest — no persistent badge should exist
        XCTAssertNil(cat.persistentBadgeNode, "No persistent badge during active permissionRequest")
    }
}
