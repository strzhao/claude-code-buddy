import CoreGraphics
import Foundation

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

struct UpdateAvailableEvent {
    let currentVersion: String
    let newVersion: String
    let htmlURL: URL
}

// Placeholder types for task 008
enum WeatherState: String, CaseIterable {
    case clear, cloudy, rain, snow, wind
}

enum TimeOfDay: String, CaseIterable {
    case morning, afternoon, evening, night
}

extension WeatherState {
    var behaviorModifier: BehaviorModifier {
        switch self {
        case .clear:  return .clear
        case .cloudy: return .cloudy
        case .rain:   return .rain
        case .snow:   return .snow
        case .wind:   return .wind
        }
    }
}

extension TimeOfDay {
    static var current: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default:     return .night
        }
    }
}
