import CoreGraphics

struct SessionEvent {
    let sessionId: String
    let info: SessionInfo
}

struct StateChangeEvent {
    let sessionId: String
    let newState: EntityState
    let toolDescription: String?
}

struct LabelChangeEvent {
    let sessionId: String
    let newLabel: String
}

struct FoodSpawnEvent {
    let nearX: CGFloat
}

// Placeholder types for task 008
enum WeatherState: String, CaseIterable {
    case clear, cloudy, rain, snow, wind
}

enum TimeOfDay: String, CaseIterable {
    case morning, afternoon, evening, night
}
