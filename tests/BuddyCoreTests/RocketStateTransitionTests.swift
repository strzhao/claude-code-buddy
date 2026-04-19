import XCTest
import Combine
@testable import BuddyCore

final class RocketStateTransitionTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testThinking_fromPadTakesOff() {
        let r = RocketEntity(sessionId: "t1")
        r.handle(event: .thinking)
        // thinking = user gave a command → rocket lifts off
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testToolEnd_staysInFlight() {
        let r = RocketEntity(sessionId: "t1b")
        r.handle(event: .thinking)
        XCTAssertEqual(r.currentState, .cruising)
        r.handle(event: .toolEnd(name: "Read"))
        // tool_end does NOT return to pad; rocket stays airborne until task_complete.
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testToolStart_onPad_doesNotLiftOff() {
        // Takeoff is gated to UserPromptSubmit (.thinking). Internal tool churn
        // (PreToolUse → .toolStart) must not lift an on-pad rocket.
        let r = RocketEntity(sessionId: "t2")
        r.handle(event: .toolStart(name: "Read", description: nil))
        XCTAssertEqual(r.currentState, .onPad)
    }

    func testToolStart_fromAbort_resumesCruising() {
        // User approved the permission → tool is now running → rocket comes
        // out of abortStandby back into flight.
        let r = RocketEntity(sessionId: "t2b")
        r.handle(event: .thinking)
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)
        r.handle(event: .toolStart(name: "Read", description: nil))
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
