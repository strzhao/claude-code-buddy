import CoreGraphics
import Foundation

struct SessionLifecycleEvent {
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

/// Request to temporarily grow the Dock window upward (used by rocket dramatic states).
struct SceneExpansionRequest {
    let height: CGFloat
    let duration: TimeInterval
}

/// Broadcast when the global EntityMode changes (cat ↔ rocket).
struct EntityModeChangeEvent {
    let previous: EntityMode
    let next: EntityMode
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
