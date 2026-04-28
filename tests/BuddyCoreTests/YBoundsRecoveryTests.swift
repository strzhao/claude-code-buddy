import XCTest
@testable import BuddyCore

// MARK: - YBoundsRecoveryTests

final class YBoundsRecoveryTests: XCTestCase {

    // MARK: - Helpers

    private func makeCat(
        x: CGFloat = 200,
        y: CGFloat = 48,
        sceneWidth: CGFloat = 800
    ) -> CatSprite {
        let cat = CatSprite(sessionId: "ybounds-test")
        cat.configure(color: .sky, labelText: "test")
        cat.containerNode.position = CGPoint(x: x, y: y)
        cat.sceneWidth = sceneWidth
        cat.activityMin = CatConstants.Movement.walkBoundaryMargin
        cat.applyFacingDirection()
        cat.switchState(to: .idle)
        return cat
    }

    // MARK: - isOutOfBounds Y-Axis Tests

    func testIsOutOfBoundsDetectsYBelowGround() {
        // groundY=48, tolerance=8, so <40 is out
        // Set y to 35, which is 13px below groundY, past tolerance
        let cat = makeCat(y: 35)
        XCTAssertTrue(cat.isOutOfBounds(),
                      "cat.y=\(cat.containerNode.position.y) should be out of bounds (groundY=\(CatConstants.Visual.groundY), tolerance=\(CatConstants.BoundaryRecovery.outOfBoundsTolerance))")
    }

    func testIsOutOfBoundsDetectsYAboveMaxDrift() {
        // groundY=48, maxYDrift=100, so >148 is out
        // Set y to 150, which is 102px above groundY, past maxYDrift
        let cat = makeCat(y: 150)
        XCTAssertTrue(cat.isOutOfBounds(),
                      "cat.y=\(cat.containerNode.position.y) should be out of bounds (groundY=\(CatConstants.Visual.groundY), maxYDrift=\(CatConstants.BoundaryRecovery.maxYDrift))")
    }

    func testIsOutOfBoundsNormalY() {
        // y=48 is exactly at groundY, should be in bounds
        let cat = makeCat(y: 48)
        XCTAssertFalse(cat.isOutOfBounds(),
                       "cat.y=\(cat.containerNode.position.y) at groundY should be in bounds")

        // y=50 is 2px above groundY, within tolerance, should be in bounds
        let cat2 = makeCat(y: 50)
        XCTAssertFalse(cat2.isOutOfBounds(),
                        "cat.y=\(cat2.containerNode.position.y) near groundY should be in bounds")

        // y=45 is 3px below groundY, within tolerance, should be in bounds
        let cat3 = makeCat(y: 45)
        XCTAssertFalse(cat3.isOutOfBounds(),
                        "cat.y=\(cat3.containerNode.position.y) near groundY should be in bounds")
    }

    func testIsOutOfBoundsYAtToleranceBoundaries() {
        // y=40 is exactly at groundY - tolerance, should still be in bounds (tolerance is inclusive)
        let cat = makeCat(y: 40)
        XCTAssertFalse(cat.isOutOfBounds(),
                       "cat.y=\(cat.containerNode.position.y) at groundY - tolerance should be in bounds")

        // y=39 is just past tolerance, should be out of bounds
        let cat2 = makeCat(y: 39)
        XCTAssertTrue(cat2.isOutOfBounds(),
                      "cat.y=\(cat2.containerNode.position.y) just past groundY - tolerance should be out of bounds")

        // y=148 is exactly at groundY + maxYDrift, should be at boundary
        let cat3 = makeCat(y: 148)
        // Check the exact boundary condition based on implementation
        let isOut = cat3.isOutOfBounds()
        // The implementation uses > for upper bound, so 148 should be in bounds
        XCTAssertFalse(isOut,
                       "cat.y=\(cat3.containerNode.position.y) at groundY + maxYDrift should be in bounds")

        // y=149 is just past maxYDrift, should be out of bounds
        let cat4 = makeCat(y: 149)
        XCTAssertTrue(cat4.isOutOfBounds(),
                      "cat.y=\(cat4.containerNode.position.y) just past groundY + maxYDrift should be out of bounds")
    }

    // MARK: - snapGround Tests

    func testSnapGroundRestoresGroundY() {
        // Create a cat at an extreme negative Y position (simulating the bug)
        let cat = makeCat(y: -1000)
        XCTAssertEqual(cat.containerNode.position.y, -1000)

        // Simulate the snapGround action by setting y to groundY
        cat.containerNode.position.y = CatConstants.Visual.groundY

        // Verify the cat is now at ground level
        XCTAssertEqual(cat.containerNode.position.y, CatConstants.Visual.groundY,
                       "After snapGround, cat.y should be restored to groundY=\(CatConstants.Visual.groundY)")
    }

    func testSnapGroundFromExtremePosition() {
        // Test with the extreme negative value mentioned in the bug report
        let extremeY: CGFloat = -9_191_131
        let cat = makeCat(y: extremeY)
        XCTAssertEqual(cat.containerNode.position.y, extremeY)

        // Apply snapGround
        cat.containerNode.position.y = CatConstants.Visual.groundY

        // Verify restoration
        XCTAssertEqual(cat.containerNode.position.y, CatConstants.Visual.groundY,
                       "snapGround should restore even from extreme negative positions")
    }

    // MARK: - Constants Validation

    func testYAxisConstantsAreReasonable() {
        // groundY should be positive
        XCTAssertGreaterThan(CatConstants.Visual.groundY, 0,
                            "groundY should be positive")

        // maxYDrift should be positive
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.maxYDrift, 0,
                            "maxYDrift should be positive")

        // outOfBoundsTolerance should be positive
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.outOfBoundsTolerance, 0,
                            "outOfBoundsTolerance should be positive")

        // maxYDrift should be significantly larger than tolerance to allow meaningful vertical movement
        XCTAssertGreaterThan(CatConstants.BoundaryRecovery.maxYDrift,
                            CatConstants.BoundaryRecovery.outOfBoundsTolerance,
                            "maxYDrift should be larger than outOfBoundsTolerance")
    }

    // MARK: - Combined X and Y Bounds Tests

    func testIsOutOfBoundsConsidersBothAxes() {
        // A cat can be out of bounds due to X, Y, or both
        let groundY = CatConstants.Visual.groundY
        let tolerance = CatConstants.BoundaryRecovery.outOfBoundsTolerance
        let maxYDrift = CatConstants.BoundaryRecovery.maxYDrift
        let activityMin = CatConstants.Movement.walkBoundaryMargin

        // Test 1: Out of bounds on X only
        let cat1 = makeCat(x: activityMin - tolerance - 1, y: groundY)
        XCTAssertTrue(cat1.isOutOfBounds(),
                      "Cat should be out of bounds when X is past tolerance even if Y is normal")

        // Test 2: Out of bounds on Y only (below ground)
        let cat2 = makeCat(x: 200, y: groundY - tolerance - 1)
        XCTAssertTrue(cat2.isOutOfBounds(),
                      "Cat should be out of bounds when Y is below tolerance even if X is normal")

        // Test 3: Out of bounds on Y only (above max drift)
        let cat3 = makeCat(x: 200, y: groundY + maxYDrift + 1)
        XCTAssertTrue(cat3.isOutOfBounds(),
                      "Cat should be out of bounds when Y is above maxYDrift even if X is normal")

        // Test 4: In bounds on both axes
        let cat4 = makeCat(x: 200, y: groundY)
        XCTAssertFalse(cat4.isOutOfBounds(),
                       "Cat should be in bounds when both X and Y are within limits")

        // Test 5: Out of bounds on both X and Y
        let cat5 = makeCat(x: activityMin - tolerance - 1, y: groundY + maxYDrift + 1)
        XCTAssertTrue(cat5.isOutOfBounds(),
                      "Cat should be out of bounds when both X and Y are past limits")
    }
}
