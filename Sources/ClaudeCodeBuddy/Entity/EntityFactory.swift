import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
/// Phase 1: .rocket falls back to CatEntity since RocketEntity is not yet implemented.
/// Step 3 of plan will replace the fallback with a real RocketEntity.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:
            return CatEntity(sessionId: sessionId)
        case .rocket:
            NSLog("[EntityFactory] .rocket not implemented yet; falling back to .cat")
            return CatEntity(sessionId: sessionId)
        }
    }
}
