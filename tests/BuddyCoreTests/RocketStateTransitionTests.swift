import XCTest
import Combine
@testable import BuddyCore

final class RocketStateTransitionTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testThinking_entersSystemsCheck() {
        let r = RocketEntity(sessionId: "t1")
        r.handle(event: .thinking)
        XCTAssertEqual(r.currentState, .systemsCheck)
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

    func testPropulsiveLanding_emitsSceneExpansionRequest() {
        let r = RocketEntity(sessionId: "t5")
        let exp = expectation(description: "emits expansion")
        var receivedHeight: CGFloat?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                receivedHeight = req.height
                exp.fulfill()
            }
            .store(in: &cancellables)
        r.handle(event: .taskComplete)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedHeight, RocketConstants.Landing.sceneExpansion)
    }

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
