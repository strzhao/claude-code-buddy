import Combine
import Foundation

/// Manages the scene's environmental state (weather, time of day)
class SceneEnvironment {
    private(set) var currentWeather: WeatherState = .clear
    private(set) var currentTimeOfDay: TimeOfDay = .current

    private var timeCheckTimer: Timer?

    func start() {
        // Check time of day every minute
        timeCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkTimeOfDay()
        }
        checkTimeOfDay()
    }

    func setWeather(_ weather: WeatherState) {
        guard weather != currentWeather else { return }
        currentWeather = weather
        EventBus.shared.weatherChanged.send(weather)
    }

    private func checkTimeOfDay() {
        let newTime = TimeOfDay.current
        guard newTime != currentTimeOfDay else { return }
        currentTimeOfDay = newTime
        EventBus.shared.timeOfDayChanged.send(newTime)
    }

    func stop() {
        timeCheckTimer?.invalidate()
        timeCheckTimer = nil
    }
}
