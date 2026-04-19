import XCTest
@testable import BuddyCore

/// Guard-condition tests for `RocketEntity.handle(event:)` — mirrors the
/// `CatEntityStateGuardTests` pattern. Covers the three behavioral guards
/// that are NOT obvious from the raw event→state mapping:
///
///   1. Abort (`!`) persists through `thinking` heartbeats — only a real
///      tool run (`toolStart`) or `taskComplete` clears it.
///   2. In-flight states (`cruising` / `propulsiveLanding` / `liftoff`) are
///      sticky — a duplicate `thinking` / `toolStart` event does not re-enter
///      Cruising and therefore doesn't restart the liftoff animation.
///   3. Lifecycle events (`sessionStart`, `sessionEnd`, `permissionRequest`,
///      `taskComplete`) always transition regardless of current state.
final class RocketStateGuardTests: XCTestCase {

    // MARK: - Helpers

    private func makeRocket(_ id: String = "guard-test") -> RocketEntity {
        RocketEntity(sessionId: id)
    }

    // MARK: - Abort persistence

    func testThinkingDuringAbort_preservesAbort() {
        let r = makeRocket("abort-persist-thinking")
        r.handle(event: .permissionRequest(description: "confirm"))
        XCTAssertEqual(r.currentState, .abortStandby)

        r.handle(event: .thinking)
        XCTAssertEqual(r.currentState, .abortStandby,
                       "thinking heartbeat must not clear the ! badge")
    }

    func testToolStartDuringAbort_clearsAbortToCruising() {
        let r = makeRocket("abort-clear-toolstart")
        r.handle(event: .permissionRequest(description: "confirm"))
        XCTAssertEqual(r.currentState, .abortStandby)

        r.handle(event: .toolStart(name: "Read", description: nil))
        XCTAssertEqual(r.currentState, .cruising,
                       "toolStart should exit abort and resume flight")
    }

    func testTaskCompleteDuringAbort_entersLanding() {
        let r = makeRocket("abort-clear-complete")
        r.handle(event: .permissionRequest(description: "confirm"))
        XCTAssertEqual(r.currentState, .abortStandby)

        r.containerNode.position.y = r.kind.containerInitY + 50
        r.handle(event: .taskComplete)
        XCTAssertEqual(r.currentState, .propulsiveLanding)
    }

    // MARK: - Flight stickiness

    func testRepeatedUserPromptDuringCruising_staysInCruising() {
        let r = makeRocket("flight-sticky-prompt")
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)

        r.handle(event: .userPromptSubmit)
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising,
                       "duplicate userPromptSubmit must not restart liftoff while cruising")
    }

    func testToolEndDuringCruising_staysInCruising() {
        let r = makeRocket("flight-sticky-toolend")
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)

        r.handle(event: .toolEnd(name: "Read"))
        XCTAssertEqual(r.currentState, .cruising,
                       "tool_end alone is not a landing signal")
    }

    // MARK: - Lifecycle

    func testSessionStart_resetsToOnPad() {
        let r = makeRocket("lifecycle-reset")
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)

        r.handle(event: .sessionStart)
        XCTAssertEqual(r.currentState, .onPad)
    }

    func testSessionEnd_entersLiftoff() {
        let r = makeRocket("lifecycle-end")
        r.handle(event: .sessionEnd)
        XCTAssertEqual(r.currentState, .liftoff)
    }

    // MARK: - Hover (rocket is intentionally a no-op so state shouldn't change)

    func testHoverEnter_doesNotChangeState() {
        let r = makeRocket("hover-enter")
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)

        r.handle(event: .hoverEnter)
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testHoverExit_doesNotChangeState() {
        let r = makeRocket("hover-exit")
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)

        r.handle(event: .hoverExit)
        XCTAssertEqual(r.currentState, .abortStandby)
    }
}
