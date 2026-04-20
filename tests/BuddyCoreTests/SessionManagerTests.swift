import XCTest
import Combine
@testable import BuddyCore

// MARK: - SessionManagerTests

/// Fine-grained unit tests for SessionManager behavior.
/// Acceptance-level scenarios are in SessionManagerAcceptanceTests.
final class SessionManagerTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    // MARK: - Session Lifecycle

    func testFirstMessageCreatesSessionWithCorrectFields() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "thinking", cwd: "/repos/my-project", pid: 12345
        ))
        let info = manager.sessions["s1"]
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.sessionId, "s1")
        XCTAssertEqual(info?.label, "my-project")
        XCTAssertEqual(info?.cwd, "/repos/my-project")
        XCTAssertEqual(info?.pid, 12345)
        XCTAssertEqual(info?.state, .thinking)
        XCTAssertEqual(info?.toolCallCount, 0)
    }

    func testSessionStartMapsToNilEntityState() {
        // sessionStart has nil entityState → session created with .idle default
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_start"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .idle)
        // No updateCatState call since entityState is nil
        XCTAssertTrue(scene.updateStateCalls.isEmpty)
    }

    func testSecondMessageUpdatesLastActivity() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        let first = manager.sessions["s1"]!.lastActivity

        // Small delay not needed — Date() in handle() is always >= first
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "idle"))
        let second = manager.sessions["s1"]!.lastActivity
        XCTAssertGreaterThanOrEqual(second, first)
    }

    func testSessionEndDuringToolUseReleasesColor() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_start"))
        XCTAssertEqual(manager.usedColors.count, 1)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_end"))
        XCTAssertTrue(manager.usedColors.isEmpty)
        XCTAssertNil(manager.sessions["s1"])
    }

    func testMultipleSessionsIndependent() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "a", event: "thinking", cwd: "/a"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "b", event: "tool_start", cwd: "/b"))

        XCTAssertEqual(manager.sessions["a"]?.state, .thinking)
        XCTAssertEqual(manager.sessions["b"]?.state, .toolUse)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "a", event: "session_end"))
        XCTAssertNil(manager.sessions["a"])
        XCTAssertNotNil(manager.sessions["b"])
    }

    // MARK: - State Machine

    func testToolEndMapsToThinking() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_start"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_end"))
        XCTAssertEqual(manager.sessions["s1"]?.state, .thinking)
    }

    func testToolDescriptionPassedForPermissionRequest() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "permission_request", description: "Run: rm -rf /"
        ))
        XCTAssertEqual(manager.sessions["s1"]?.toolDescription, "Run: rm -rf /")
        XCTAssertEqual(scene.updateStateCalls.last?.desc, "Run: rm -rf /")
    }

    func testToolDescriptionFallsBackToToolName() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "tool_start", tool: "Bash"
        ))
        XCTAssertEqual(manager.sessions["s1"]?.toolDescription, "Bash")
    }

    func testSetLabelDoesNotMapToEntityState() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        let stateCallsBefore = scene.updateStateCalls.count

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "set_label", label: "new-name"
        ))
        // set_label should NOT trigger updateCatState
        XCTAssertEqual(scene.updateStateCalls.count, stateCallsBefore)
    }

    // MARK: - Color Pool

    func testPoolExhaustedReturnsFirstColor() {
        // Fill all 8 colors
        for i in 1...8 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/p\(i)"
            ))
        }
        XCTAssertEqual(manager.usedColors.count, 8)

        // 9th session: pool exhausted → gets allCases[0]
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s9", event: "thinking", cwd: "/p9"
        ))
        XCTAssertEqual(manager.sessions["s9"]?.color, SessionColor.allCases[0])
    }

    func testReleasedColorIsFirstAvailable() {
        for i in 1...3 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/p\(i)"
            ))
        }
        let secondColor = manager.sessions["s2"]!.color
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s2", event: "session_end"))

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s4", event: "thinking", cwd: "/p4"
        ))
        XCTAssertEqual(manager.sessions["s4"]?.color, secondColor)
    }

    // MARK: - Label Generation

    func testLabelFromNestedPath() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "thinking", cwd: "/Users/alice/workspace/deep/nested/project"
        ))
        XCTAssertEqual(manager.sessions["s1"]?.label, "project")
    }

    func testThreeSameCwdThirdAlsoGetsSuffix() {
        for i in 1...3 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/repos/app"
            ))
        }
        XCTAssertEqual(manager.sessions["s1"]?.label, "app")
        XCTAssertEqual(manager.sessions["s2"]?.label, "app②")
        // Third also gets ② because generateLabel checks `filter { $0.label == base }.count > 0`
        // At this point "app" exists (s1), so s3 also gets "app②"
        XCTAssertEqual(manager.sessions["s3"]?.label, "app②")
    }

    // MARK: - Cat Cap

    func testAfterRemovalNewSessionGetsAddCat() {
        for i in 1...8 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/p\(i)"
            ))
        }
        XCTAssertEqual(scene.addCatCalls.count, 8)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_end"))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s9", event: "thinking", cwd: "/p9"
        ))
        // After removal, activeCatCount dropped to 7, so s9 gets addCat
        XCTAssertEqual(scene.addCatCalls.count, 9)
    }

    // MARK: - Food Spawn

    func testToolEndMayTriggerFoodSpawn() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        scene.stubbedCatPositions["s1"] = 200.0

        // Send many tool_end messages to overcome randomness
        for _ in 0..<200 {
            manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_end"))
        }
        XCTAssertGreaterThan(scene.spawnFoodCalls.count, 0, "At least some tool_end should spawn food")
        XCTAssertTrue(scene.catPositionCalls.contains("s1"))
    }

    func testNonToolEndDoesNotSpawnFood() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_start"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "idle"))
        XCTAssertTrue(scene.spawnFoodCalls.isEmpty)
    }

    func testToolEndSpawnProbabilityReasonable() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        scene.stubbedCatPositions["s1"] = 100.0

        for _ in 0..<1000 {
            manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_end"))
        }
        let count = scene.spawnFoodCalls.count
        // 35% probability: expect ~350, assert within ≈6σ
        XCTAssertTrue(abs(count - 350) < 100,
                      "Spawn count \(count) should be near 350 (35% of 1000)")
    }

    // MARK: - Timeout

    func testCheckTimeoutsWithMixedAges() {
        // Fresh session
        manager.handle(message: TestHelpers.makeMessage(sessionId: "fresh", event: "thinking", cwd: "/a"))

        // Idle-timeout session (6 min)
        manager.handle(message: TestHelpers.makeMessage(sessionId: "stale", event: "thinking", cwd: "/b"))
        manager.sessions["stale"]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))

        // Remove-timeout session (31 min)
        manager.handle(message: TestHelpers.makeMessage(sessionId: "dead", event: "thinking", cwd: "/c"))
        manager.sessions["dead"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        XCTAssertEqual(manager.sessions["fresh"]?.state, .thinking, "Fresh session unchanged")
        XCTAssertEqual(manager.sessions["stale"]?.state, .idle, "Stale session → idle")
        XCTAssertNil(manager.sessions["dead"], "Dead session removed")
        XCTAssertTrue(scene.removeCatCalls.contains("dead"))
        XCTAssertFalse(scene.removeCatCalls.contains("fresh"))
        XCTAssertFalse(scene.removeCatCalls.contains("stale"))
    }

    func testCheckTimeoutsRecentSessionUntouched() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        manager.checkTimeouts()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions["s1"]?.state, .thinking)
        XCTAssertTrue(scene.removeCatCalls.isEmpty)
    }

    func testCheckTimeoutsReleasesColor() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        let color = manager.sessions["s1"]!.color
        manager.sessions["s1"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()
        XCTAssertFalse(manager.usedColors.contains(color))
    }

    func testCheckTimeoutsKeepsSessionWithAliveProcess() {
        // Session with PID of current process (definitely alive)
        manager.handle(message: TestHelpers.makeMessage(sessionId: "alive", event: "thinking", cwd: "/a"))
        manager.sessions["alive"]?.pid = Int(ProcessInfo.processInfo.processIdentifier)  // current process, always alive
        manager.sessions["alive"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions["alive"], "Session with alive process should not be removed")
        XCTAssertEqual(manager.sessions["alive"]?.state, .idle, "Should be set to idle")
        XCTAssertFalse(scene.removeCatCalls.contains("alive"))
    }

    func testCheckTimeoutsRemovesSessionWithDeadProcess() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "dead", event: "thinking", cwd: "/a"))
        manager.sessions["dead"]?.pid = 99999  // very likely not running
        manager.sessions["dead"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        XCTAssertNil(manager.sessions["dead"], "Session with dead process should be removed")
        XCTAssertTrue(scene.removeCatCalls.contains("dead"))
    }

    func testCheckTimeoutsRemovesSessionWithNoPid() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "nopid", event: "thinking", cwd: "/a"))
        manager.sessions["nopid"]?.pid = nil
        manager.sessions["nopid"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        XCTAssertNil(manager.sessions["nopid"], "Session with no PID should be removed after timeout")
        XCTAssertTrue(scene.removeCatCalls.contains("nopid"))
    }

    func testCheckTimeoutsNoRemovalDoesNotFireCallbacks() {        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        var callbackFired = false
        manager.onSessionCountChanged = { _ in callbackFired = true }

        manager.checkTimeouts()
        XCTAssertFalse(callbackFired, "Callbacks should not fire if no sessions were removed")
    }

    // MARK: - CWD Enrichment

    func testCwdNotOverwrittenIfAlreadySet() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "thinking", cwd: "/original"
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "idle", cwd: "/different"
        ))
        XCTAssertEqual(manager.sessions["s1"]?.cwd, "/original")
    }

    func testPidEnriched() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        XCTAssertNil(manager.sessions["s1"]?.pid)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "idle", pid: 42))
        XCTAssertEqual(manager.sessions["s1"]?.pid, 42)
    }

    func testPidNotOverwrittenIfAlreadySet() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", pid: 100))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "idle", pid: 200))
        XCTAssertEqual(manager.sessions["s1"]?.pid, 100)
    }

    func testTerminalIdTriggersTabTitleCallback() {
        var callbackSession: SessionInfo?
        manager.onSessionNeedsTabTitle = { callbackSession = $0 }

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        XCTAssertNil(callbackSession, "No callback without terminalId")

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "idle", terminalId: "UUID-XYZ"
        ))
        XCTAssertNotNil(callbackSession)
        XCTAssertEqual(callbackSession?.terminalId, "UUID-XYZ")
    }

    func testTerminalIdOnFirstMessageTriggersCallback() {
        var called = false
        manager.onSessionNeedsTabTitle = { _ in called = true }

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "thinking", terminalId: "T1"
        ))
        XCTAssertTrue(called)
    }

    // MARK: - Color File

    func testColorFileStructure() throws {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "thinking", cwd: "/repos/test"
        ))

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )
        let entry = try XCTUnwrap(json["s1"])
        XCTAssertNotNil(entry["color"])
        XCTAssertNotNil(entry["hex"])
        XCTAssertEqual(entry["label"], "test")
    }

    func testColorFileEmptyAfterAllSessionsEnd() throws {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_end"))

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )
        XCTAssertTrue(json.isEmpty)
    }

    // MARK: - Callbacks

    func testOnSessionCountChangedUsesActiveCatCount() {
        var receivedCount: Int?
        manager.onSessionCountChanged = { receivedCount = $0 }

        // Create 9 sessions (only 8 cats)
        for i in 1...9 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/p\(i)"
            ))
        }
        // activeCatCount is 8 (MockScene tracks this), not sessions.count (9)
        XCTAssertEqual(receivedCount, 8)
    }

    // MARK: - Tool Call Count

    func testToolStartIncrements() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        XCTAssertEqual(manager.sessions["s1"]?.toolCallCount, 0)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_start"))
        XCTAssertEqual(manager.sessions["s1"]?.toolCallCount, 1)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_start"))
        XCTAssertEqual(manager.sessions["s1"]?.toolCallCount, 2)
    }

    func testOtherEventsDoNotIncrementToolCallCount() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "idle"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "tool_end"))
        XCTAssertEqual(manager.sessions["s1"]?.toolCallCount, 0)
    }

    // MARK: - EventBus

    func testStateChangePublishesAllFields() {
        var received: StateChangeEvent?
        var cancellables = Set<AnyCancellable>()
        EventBus.shared.stateChanged
            .sink { received = $0 }
            .store(in: &cancellables)

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "tool_start", tool: "Bash", description: "ls -la"
        ))

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.sessionId, "s1")
        XCTAssertEqual(received?.newState, .toolUse)
        XCTAssertEqual(received?.toolDescription, "ls -la")
    }

    func testNoEventBusPublishForLifecycleOnlyEvents() {
        var received = false
        var cancellables = Set<AnyCancellable>()
        EventBus.shared.stateChanged
            .sink { _ in received = true }
            .store(in: &cancellables)

        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_start"))
        XCTAssertFalse(received, "session_start has nil entityState, should not publish")
    }
}
