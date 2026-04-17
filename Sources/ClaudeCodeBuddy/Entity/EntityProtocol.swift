import SpriteKit

// MARK: - EntityProtocol

/// Protocol defining the public interface for any scene entity (cat, dog, etc.).
/// CatEntity conforms to this protocol. Full decoupling of closure types referencing
/// CatEntity happens in task 007-eventbus.
protocol EntityProtocol: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var currentState: CatState { get }
    func switchState(to state: CatState, toolDescription: String?)
    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?)
    func applyHoverScale()
    func removeHoverScale()
    func updateSceneSize(_ size: CGSize)
    func playFrightReaction(awayFromX jumperX: CGFloat)
    var isDebugCat: Bool { get }
    var sessionColor: SessionColor? { get }
}
