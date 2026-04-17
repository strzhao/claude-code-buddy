import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:    return CatEntity(sessionId: sessionId)
        case .rocket: return RocketEntity(sessionId: sessionId)
        }
    }
}
