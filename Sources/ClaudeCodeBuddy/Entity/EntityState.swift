// MARK: - EntityState

/// Generic entity state, mirrors CatState.
/// Will replace CatState in cross-layer interfaces in task 007-eventbus.
enum EntityState: String, CaseIterable {
    case idle              = "idle"
    case thinking          = "thinking"
    case toolUse           = "tool_use"
    case permissionRequest = "waiting"
    case eating            = "eating"
    case taskComplete      = "task_complete"
}
