import Foundation

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
}
