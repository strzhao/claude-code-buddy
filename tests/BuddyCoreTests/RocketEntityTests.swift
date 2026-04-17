import XCTest
@testable import BuddyCore

final class RocketEntityTests: XCTestCase {

    func testInit_hasSessionId() {
        let r = RocketEntity(sessionId: "r1")
        XCTAssertEqual(r.sessionId, "r1")
    }

    func testInit_containerNodeSetup() {
        let r = RocketEntity(sessionId: "r2")
        XCTAssertEqual(r.containerNode.name, "rocket_r2")
    }

    func testIsDebug_true() {
        let r = RocketEntity(sessionId: "debug-X")
        XCTAssertTrue(r.isDebug)
    }

    func testConfigureColor() {
        let r = RocketEntity(sessionId: "r3")
        r.configure(color: .coral, labelText: "test")
        XCTAssertEqual(r.sessionColor, .coral)
    }

    func testInitialState_onPad() {
        let r = RocketEntity(sessionId: "r4")
        XCTAssertEqual(r.currentState, .onPad)
    }
}
