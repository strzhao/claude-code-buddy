import SpriteKit

// MARK: - EntityProtocol

/// Protocol defining the public interface for any scene entity (cat, dog, etc.).
/// CatSprite conforms to this protocol. Full decoupling of closure types referencing
/// CatSprite happens in task 007-eventbus.
protocol EntityProtocol: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var currentState: CatState { get }
    func switchState(to state: CatState, toolDescription: String?)
    func enterScene(sceneSize: CGSize)
    func applyHoverScale()
    func removeHoverScale()
    func updateSceneSize(_ size: CGSize)
    func playFrightReaction(awayFromX jumperX: CGFloat)
    var isDebugCat: Bool { get }
    var sessionColor: SessionColor? { get }
}
