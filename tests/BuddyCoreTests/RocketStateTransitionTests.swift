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

    func testToolStart_entersCruising() {
        let r = RocketEntity(sessionId: "t2")
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
