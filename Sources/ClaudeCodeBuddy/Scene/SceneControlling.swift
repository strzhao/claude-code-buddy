import Foundation

/// Snapshot of a cat's visual state for query responses.
struct CatSnapshot {
    let sessionId: String
    let x: CGFloat
    let y: CGFloat
    let state: String
    let facingRight: Bool
    let isDebug: Bool
    let activityBoundsMin: CGFloat
    let activityBoundsMax: CGFloat

    func toDict() -> [String: Any] {
        [
            "session_id": sessionId,
            "x": x,
            "y": y,
            "state": state,
            "facing_right": facingRight,
            "is_debug": isDebug,
            "activity_bounds": [activityBoundsMin, activityBoundsMax],
        ]
    }
}

/// Snapshot of overall scene state.
struct SceneSnapshot {
    let visible: Bool
    let catsRendered: Int
    let boundsMin: CGFloat
    let boundsMax: CGFloat

    func toDict() -> [String: Any] {
        [
            "visible": visible,
            "cats_rendered": catsRendered,
            "bounds": [boundsMin, boundsMax],
        ]
    }
}

/// Protocol abstracting the scene interface that SessionManager depends on.
/// Enables testing SessionManager with a mock scene instead of a real BuddyScene.
protocol SceneControlling: AnyObject {
    var activeCatCount: Int { get }
    func addCat(info: SessionInfo)
    func removeCat(sessionId: String)
    func updateCatState(sessionId: String, state: CatState, toolDescription: String?)
    func updateCatLabel(sessionId: String, label: String)
    func catPosition(for sessionId: String) -> CGFloat?
    func spawnFood(near x: CGFloat?)
    func assignBedSlot(for sessionId: String) -> CGFloat?
    func releaseBedSlot(for sessionId: String)
    func bedColorName(for sessionId: String) -> String?

    // MARK: - Query Support

    func catSnapshot(for sessionId: String) -> CatSnapshot?
    func allCatSnapshots() -> [CatSnapshot]
    func sceneSnapshot() -> SceneSnapshot

    // MARK: - Entity API (mode-agnostic, added in Step 4)

    func addEntity(info: SessionInfo, mode: EntityMode)
    func removeEntity(sessionId: String)
    func replaceAllEntities(with mode: EntityMode,
                            infos: [SessionInfo],
                            lastEvents: [String: EntityInputEvent],
                            completion: @escaping () -> Void)
    func dispatchEntityEvent(sessionId: String, event: EntityInputEvent)
}
