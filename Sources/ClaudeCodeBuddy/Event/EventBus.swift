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

    /// Requests a full app relaunch. Value = the new EntityMode to persist
    /// before relaunch (or nil to restart without changing mode). AppDelegate
    /// handles it: plays exit animation, then spawns a new process + exits
    /// the current one. Used by the settings mode-toggle (to avoid the race
    /// conditions of rapid hot-switches) and the Reset button.
    let relaunchRequested = PassthroughSubject<EntityMode?, Never>()

    // Environment events (for task 008)
    let weatherChanged = PassthroughSubject<WeatherState, Never>()
    let timeOfDayChanged = PassthroughSubject<TimeOfDay, Never>()

    private init() {}
}
