import Combine

final class EventBus {
    static let shared = EventBus()

    // Session lifecycle events
    let sessionStarted = PassthroughSubject<SessionEvent, Never>()
    let sessionEnded = PassthroughSubject<SessionEvent, Never>()
    let stateChanged = PassthroughSubject<StateChangeEvent, Never>()
    let labelChanged = PassthroughSubject<LabelChangeEvent, Never>()

    // Food events
    let foodSpawnRequested = PassthroughSubject<FoodSpawnEvent, Never>()

    // Environment events (for task 008)
    let weatherChanged = PassthroughSubject<WeatherState, Never>()
    let timeOfDayChanged = PassthroughSubject<TimeOfDay, Never>()

    // Update events
    let updateAvailable = PassthroughSubject<UpdateAvailableEvent, Never>()
    let upgradeCompleted = PassthroughSubject<Void, Never>()

    private init() {}
}
