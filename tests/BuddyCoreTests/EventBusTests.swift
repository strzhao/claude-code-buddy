import XCTest
import Combine
@testable import BuddyCore

final class EventBusTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    func testStateChangedReceivesEvent() {
        var received: StateChangeEvent?
        EventBus.shared.stateChanged
            .sink { received = $0 }
            .store(in: &cancellables)

        let event = StateChangeEvent(sessionId: "s1", newState: .thinking, toolDescription: "desc", label: nil)
        EventBus.shared.stateChanged.send(event)

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.sessionId, "s1")
        XCTAssertEqual(received?.newState, .thinking)
        XCTAssertEqual(received?.toolDescription, "desc")
    }

    func testMultipleSubscribersReceive() {
        var count = 0
        for _ in 0..<3 {
            EventBus.shared.stateChanged
                .sink { _ in count += 1 }
                .store(in: &cancellables)
        }

        EventBus.shared.stateChanged.send(
            StateChangeEvent(sessionId: "s1", newState: .idle, toolDescription: nil, label: nil)
        )
        XCTAssertEqual(count, 3)
    }

    func testWeatherChangedSubject() {
        var received: WeatherState?
        EventBus.shared.weatherChanged
            .sink { received = $0 }
            .store(in: &cancellables)

        EventBus.shared.weatherChanged.send(.rain)
        XCTAssertEqual(received, .rain)
    }

    func testTimeOfDayChangedSubject() {
        var received: TimeOfDay?
        EventBus.shared.timeOfDayChanged
            .sink { received = $0 }
            .store(in: &cancellables)

        EventBus.shared.timeOfDayChanged.send(.night)
        XCTAssertEqual(received, .night)
    }
}
