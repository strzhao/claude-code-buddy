/// Generic input event passed to any SessionEntity.
/// Each entity (CatEntity / RocketEntity) translates these into its own state machine.
/// Decoupled from HookEvent (network layer) and EntityState (display layer).
enum EntityInputEvent {
    case sessionStart
    /// The user started a new turn (hook: UserPromptSubmit). Distinct from
    /// `.thinking` (which comes from Claude's Notification hook) so that the
    /// rocket can gate takeoff purely to "user talked", while cats can treat
    /// both as the same thinking-pose signal.
    case userPromptSubmit
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
        case .userPromptSubmit: return .userPromptSubmit
        case .thinking:     return .thinking
        case .toolStart:    return .toolStart(name: tool, description: description)
        case .toolEnd:      return .toolEnd(name: tool)
        case .permissionRequest: return .permissionRequest(description: description)
        case .taskComplete: return .taskComplete
        case .sessionEnd:   return .sessionEnd
        case .idle:         return .thinking  // fallback; SessionManager normally filters this out
        case .setLabel:     return .thinking  // unreachable: SessionManager intercepts setLabel before calling from()
        case .setTokens:    return .thinking  // unreachable: SessionManager intercepts setTokens before calling from()
        case .morph:        return .thinking  // unreachable: SessionManager intercepts morph before calling from()
        case .showcase:     return .thinking  // unreachable: SessionManager intercepts showcase before calling from()
        }
    }
}
