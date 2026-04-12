/// Protocol for entities that respond to environment changes
protocol EnvironmentResponder: AnyObject {
    func onWeatherChanged(_ weather: WeatherState)
    func onTimeOfDayChanged(_ time: TimeOfDay)
}

// Default empty implementations — entities opt-in to specific responses
extension EnvironmentResponder {
    func onWeatherChanged(_ weather: WeatherState) {}
    func onTimeOfDayChanged(_ time: TimeOfDay) {}
}
