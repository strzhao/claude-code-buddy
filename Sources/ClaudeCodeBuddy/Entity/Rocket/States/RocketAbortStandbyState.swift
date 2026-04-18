import GameplayKit
import SpriteKit
import AppKit

final class RocketAbortStandbyState: RocketBaseState {

    private weak var bangBadge: SKNode?

    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        // Freeze in place: stop the cruise drift + lift actions but keep current altitude.
        entity.node.removeAction(forKey: "cruiseFrames")
        entity.containerNode.removeAction(forKey: "cruiseLift")
        entity.containerNode.removeAction(forKey: "cruiseDrift")

        playAbortAnimation()
        addCircledBangBadge()
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "abort")
        bangBadge?.removeAllActions()
        bangBadge?.removeFromParent()
        bangBadge = nil
    }

    private func playAbortAnimation() {
        let (frames, fps) = RocketSpriteLoader.frames(for: "abort", kind: entity.kind)
        if frames.count > 1 {
            let blink = SKAction.repeatForever(
                SKAction.animate(with: frames, timePerFrame: 1.0 / fps)
            )
            entity.node.run(blink, withKey: "abort")
        } else {
            entity.node.texture = frames.first
        }
    }

    /// Red filled circle + white "!" at natural pixel size. Added directly to
    /// the scene (NOT under the rocket's scaled containerNode), so Starship's
    /// 1.5× scale doesn't magnify it. Abort holds the rocket still, so a
    /// one-shot absolute position is enough — no follow logic needed.
    private func addCircledBangBadge() {
        guard let scene = entity.containerNode.scene else { return }

        let container = SKNode()
        let rocketPos = entity.containerNode.position
        // Offset above rocket body center. Since Starship now renders at its
        // native 72×72 size (no more runtime 1.5× scaling), badge offset is a
        // fixed 12pt that reads well above the body on all kinds — Starship's
        // body is just drawn taller natively.
        let offsetY: CGFloat = 12
        container.position = CGPoint(x: rocketPos.x, y: rocketPos.y + offsetY)
        container.zPosition = 100

        let radius: CGFloat = 8
        let circle = SKShapeNode(circleOfRadius: radius)
        circle.fillColor = .systemRed
        circle.strokeColor = NSColor.white.withAlphaComponent(0.9)
        circle.lineWidth = 1.5
        container.addChild(circle)

        let label = SKLabelNode(text: "!")
        label.fontName = "HelveticaNeue-Bold"
        label.fontSize = 12
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = .zero
        container.addChild(label)

        scene.addChild(container)
        bangBadge = container

        let pulse = SKAction.repeatForever(SKAction.sequence([
            SKAction.scale(to: 1.2, duration: 0.4),
            SKAction.scale(to: 1.0, duration: 0.4)
        ]))
        container.run(pulse)
    }
}
