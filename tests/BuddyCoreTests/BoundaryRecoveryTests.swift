import XCTest
@testable import BuddyCore

// MARK: - BoundaryRecoveryTests

final class BoundaryRecoveryTests: XCTestCase {

    // MARK: - Helpers

    private func makeCat(
        x: CGFloat = 200,
        activityMin: CGFloat = 48,
        activityMax: CGFloat = 0,
        sceneWidth: CGFloat = 800
    ) -> CatEntity {
        let cat = CatEntity(sessionId: "boundary-test")
        cat.configure(color: .sky, labelText: "test")
        cat.containerNode.position = CGPoint(x: x, y: 48)
        cat.sceneWidth = sceneWidth
        cat.activityMin = activityMin
        if activityMax > 0 {
            cat.activityMax = activityMax
        }
        cat.applyFacingDirection()
        cat.switchState(to: .idle)
        return cat
    }

    // MARK: - isOutOfBounds

    func testIsOutOfBoundsReturnsTrueWhenPastLeftBound() {
        let cat = makeCat(x: 35)  // activityMin=48, tolerance=8, so <40 is out
        XCTAssertTrue(cat.isOutOfBounds())
    }

    func testIsOutOfBoundsReturnsTrueWhenPastRightBound() {
        let cat = makeCat(x: 770, activityMax: 752)  // >760 is out
        XCTAssertTrue(cat.isOutOfBounds())
    }

    func testIsOutOfBoundsReturnsFalseWithinBounds() {
        let cat = makeCat(x: 200)
        XCTAssertFalse(cat.isOutOfBounds())
    }

    func testIsOutOfBoundsReturnsFalseWithinTolerance() {
        // x=42 is 6px past activityMin=48, within tolerance=8
        let cat = makeCat(x: 42)
        XCTAssertFalse(cat.isOutOfBounds())
    }

    func testIsOutOfBoundsReturnsTrueJustPastTolerance() {
        // x=39 is 9px past activityMin=48, past tolerance=8
        let cat = makeCat(x: 39)
        XCTAssertTrue(cat.isOutOfBounds())
    }

    // MARK: - nearestValidX

    func testNearestValidXReturnsLeftBoundPlusMargin() {
        let cat = makeCat(x: 20)
        let expected = CGFloat(48) + CatConstants.Movement.walkBoundaryMargin  // 72
        XCTAssertEqual(cat.nearestValidX(), expected)
    }

    func testNearestValidXReturnsRightBoundMinusMargin() {
        let cat = makeCat(x: 800, activityMax: 752)
        let expected = CGFloat(752) - CatConstants.Movement.walkBoundaryMargin  // 728
        XCTAssertEqual(cat.nearestValidX(), expected)
    }

    // MARK: - outOfBoundsSince tracking

    func testOutOfBoundsSinceInitiallyNil() {
        let cat = makeCat(x: 200)
        XCTAssertNil(cat.outOfBoundsSince)
    }

    func testOutOfBoundsSinceCanBeSetAndCleared() {
        let cat = makeCat(x: 200)
        cat.outOfBoundsSince = CACurrentMediaTime()
        XCTAssertNotNil(cat.outOfBoundsSince)
        cat.outOfBoundsSince = nil
        XCTAssertNil(cat.outOfBoundsSince)
    }

    // MARK: - walkBackIntoBounds

    func testWalkBackIntoBoundsSnapsWhenClose() {
        let cat = makeCat(x: 70)
        let targetX: CGFloat = 72
        // Distance is 2, which equals walkMinDistance — should snap
        cat.movementComponent.walkBackIntoBounds(targetX: targetX)
        XCTAssertEqual(cat.containerNode.position.x, targetX, accuracy: 0.1)
        XCTAssertNil(cat.outOfBoundsSince)
    }

    func testWalkBackIntoBoundsStartsWalkWhenFar() {
        let cat = makeCat(x: 10)
        let targetX: CGFloat = 72
        // Distance is 62, well above walkMinDistance — should start walk
        cat.movementComponent.walkBackIntoBounds(targetX: targetX)
        // Verify recovery action is running on containerNode
        XCTAssertNotNil(cat.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey))
    }

    func testWalkBackIntoBoundsFacesCorrectDirection() {
        let cat = makeCat(x: 10)
        // Target is to the right — should face right
        cat.movementComponent.walkBackIntoBounds(targetX: 72)
        XCTAssertTrue(cat.facingRight)
    }

    func testWalkBackIntoBoundsFacesLeftWhenTargetIsLeft() {
        let cat = makeCat(x: 800, activityMax: 752)
        // Target is to the left — should face left
        cat.movementComponent.walkBackIntoBounds(targetX: 728)
        XCTAssertFalse(cat.facingRight)
    }

    // MARK: - switchState clears recovery action

    func testSwitchStateClearsBoundaryRecoveryAction() {
        let cat = makeCat(x: 10)
        cat.movementComponent.walkBackIntoBounds(targetX: 72)
        XCTAssertNotNil(cat.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey))

        cat.switchState(to: .thinking)
        XCTAssertNil(cat.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey),
                     "switchState should clear boundaryRecovery action")
    }

    // MARK: - Constants validation

    func testBoundaryRecoveryConstantsAreReasonable() {
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.outOfBoundsTolerance, 0)
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.recoveryWalkSpeed, 0)
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.recoveryMinDuration, 0)
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.gracePeriod, 0)
        XCTAssertFalse(CatConstants.BoundaryRecovery.actionKey.isEmpty)
    }

    func testToleranceLessThanMaxFrightRebound() {
        // Fright rebound can push cat up to fleeDistance * reboundFactor = 30 * 0.5 = 15px out of bounds
        let maxRebound = CatConstants.Fright.fleeDistance * CatConstants.Fright.reboundFactor
        XCTAssertLessThan(CatConstants.BoundaryRecovery.outOfBoundsTolerance, maxRebound,
                          "Tolerance should be less than max fright rebound to catch real out-of-bounds")
    }

    func testGracePeriodCoversFrightDuration() {
        // Fright total: scared frames + slide + rebound ≈ 0.5-0.7s
        // Grace period should be enough to not interrupt
        XCTAssertGreaterThanOrEqual(CatConstants.BoundaryRecovery.gracePeriod, 0.5)
    }
}
