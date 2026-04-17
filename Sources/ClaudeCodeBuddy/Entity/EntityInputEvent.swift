/// Generic input event passed to any SessionEntity.
/// Each entity (CatEntity / RocketEntity) translates these into its own state machine.
/// Decoupled from HookEvent (network layer) and EntityState (display layer).
enum EntityInputEvent {
    case sessionStart
    case thinking
    case toolStart(name: String?, description: String?)
    case toolEnd(name: String?)
    case permissionRequest(description: String?)
    case taskComplete
    case sessionEnd
    case hoverEnter
    case hoverExit
    case externalCommand(String)   // phase 2 扩展位（如 "rud"）

    /// Convert a HookEvent + optional payload into an EntityInputEvent.
    /// set_label / idle are not translated here (handled separately by SessionManager).
    static func from(hookEvent: HookEvent, tool: String?, description: String?) -> EntityInputEvent {
        switch hookEvent {
        case .sessionStart: return .sessionStart
        case .thinking:     return .thinking
        case .toolStart:    return .toolStart(name: tool, description: description)
        case .toolEnd:      return .toolEnd(name: tool)
        case .permissionRequest: return .permissionRequest(description: description)
        case .taskComplete: return .taskComplete
        case .sessionEnd:   return .sessionEnd
        case .idle:         return .thinking  // fallback; SessionManager normally filters this out
        case .setLabel:     return .thinking  // unreachable: SessionManager intercepts setLabel before calling from()
        }
    }
}
