import XCTest
import Combine
@testable import BuddyCore

final class SceneExpansionEventTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func testPublishReceive() {
        let exp = expectation(description: "receives")
        var received: SceneExpansionRequest?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                received = req
                exp.fulfill()
            }
            .store(in: &cancellables)
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(height: 120, duration: 1.2)
        )
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received?.height, 120)
        XCTAssertEqual(received?.duration, 1.2)
    }
}
