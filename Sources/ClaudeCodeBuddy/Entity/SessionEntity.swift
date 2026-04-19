import SpriteKit

/// The abstraction boundary between SessionManager/BuddyScene and concrete entities
/// (CatEntity, RocketEntity). Must NOT contain form-specific vocabulary (cat/rocket/paw/fuel).
/// Protocol body kept under ~30 lines on purpose — keep it thin.
protocol SessionEntity: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var sessionColor: SessionColor? { get }
    var isDebug: Bool { get }

    /// Configure color + visible label after creation.
    func configure(color: SessionColor, labelText: String)
    /// Update the visible label.
    func updateLabel(_ newLabel: String)
    /// Called when the entity joins the scene.
    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?)
    /// Animate away and invoke completion when fully removed.
    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void)
    /// Propagate scene size changes.
    func updateSceneSize(_ size: CGSize)
    /// Hover feedback.
    func applyHoverScale()
    func removeHoverScale()
    /// Single entry point for all state-transition input.
    func handle(event: EntityInputEvent)
}
