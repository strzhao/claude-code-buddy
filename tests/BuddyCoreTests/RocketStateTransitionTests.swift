import XCTest
import Combine
@testable import BuddyCore

final class RocketStateTransitionTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testUserPromptSubmit_fromPadTakesOff() {
        let r = RocketEntity(sessionId: "t1")
        r.handle(event: .userPromptSubmit)
        // userPromptSubmit = user started a new turn → rocket lifts off
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testThinking_onPad_doesNotLiftOff() {
        // `.thinking` now only comes from the Notification hook (idle ping,
        // waiting-for-user prompt, etc). Those are NOT new-turn signals, so
        // an on-pad rocket must stay on the pad.
        let r = RocketEntity(sessionId: "t1-n")
        r.handle(event: .thinking)
        XCTAssertEqual(r.currentState, .onPad)
    }

    func testToolEnd_staysInFlight() {
        let r = RocketEntity(sessionId: "t1b")
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)
        r.handle(event: .toolEnd(name: "Read"))
        // tool_end does NOT return to pad; rocket stays airborne until task_complete.
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testToolStart_onPad_doesNotLiftOff() {
        // Takeoff is gated to UserPromptSubmit. Internal tool churn
        // (PreToolUse → .toolStart) must not lift an on-pad rocket.
        let r = RocketEntity(sessionId: "t2")
        r.handle(event: .toolStart(name: "Read", description: nil))
        XCTAssertEqual(r.currentState, .onPad)
    }

    func testToolStart_fromAbort_resumesCruising() {
        // User approved the permission → tool is now running → rocket comes
        // out of abortStandby back into flight.
        let r = RocketEntity(sessionId: "t2b")
        r.handle(event: .userPromptSubmit)
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)
        r.handle(event: .toolStart(name: "Read", description: nil))
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testUserPromptSubmit_fromAbort_resumesCruising() {
        // User replies with a new prompt while abort is pending — treat the
        // prompt itself as approval and resume flight.
        let r = RocketEntity(sessionId: "t2c")
        r.handle(event: .userPromptSubmit)
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)
        r.handle(event: .userPromptSubmit)
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testPermissionRequest_entersAbortStandby() {
        let r = RocketEntity(sessionId: "t3")
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)
    }

    func testTaskComplete_entersPropulsiveLanding() {
        let r = RocketEntity(sessionId: "t4")
        // Landing.didEnterConventional short-circuits to OnPad when already
        // at/below ground; put the rocket "in flight" so the transition is
        // observable (this is the case that matters at runtime too — landing
        // only fires while the rocket is airborne).
        r.containerNode.position.y = r.kind.containerInitY + 50
        r.handle(event: .taskComplete)
        XCTAssertEqual(r.currentState, .propulsiveLanding)
    }

    // Note: landing no longer requests scene expansion — rocket descends from its current
    // cruise altitude (~30pt above the pad), which fits within the normal window height.

    func testLiftoff_emitsLargerExpansion() {
        let r = RocketEntity(sessionId: "t6")
        let exp = expectation(description: "emits larger expansion")
        var receivedHeight: CGFloat?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                if req.height >= RocketConstants.Liftoff.sceneExpansion {
                    receivedHeight = req.height
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        r.handle(event: .sessionEnd)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedHeight, RocketConstants.Liftoff.sceneExpansion)
    }
}
