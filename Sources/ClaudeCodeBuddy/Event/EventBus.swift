import Combine

final class EventBus {
    static let shared = EventBus()

    // Session lifecycle events
    let sessionStarted = PassthroughSubject<SessionLifecycleEvent, Never>()
    let sessionEnded = PassthroughSubject<SessionLifecycleEvent, Never>()
    let stateChanged = PassthroughSubject<StateChangeEvent, Never>()
    let labelChanged = PassthroughSubject<LabelChangeEvent, Never>()

    // Food events
    let foodSpawnRequested = PassthroughSubject<FoodSpawnEvent, Never>()

    // Rocket / morph events
    let sceneExpansionRequested = PassthroughSubject<SceneExpansionRequest, Never>()
    let entityModeChanged = PassthroughSubject<EntityModeChangeEvent, Never>()

    // Environment events (for task 008)
    let weatherChanged = PassthroughSubject<WeatherState, Never>()
    let timeOfDayChanged = PassthroughSubject<TimeOfDay, Never>()

    private init() {}
}
