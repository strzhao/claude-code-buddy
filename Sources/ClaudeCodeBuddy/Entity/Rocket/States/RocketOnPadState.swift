import GameplayKit
import SpriteKit
import AppKit

/// OnPad = rocket sitting ready at its launch structure.
///
/// Two totally separate entry paths on `entity.kind`:
///   • Conventional rockets: play onpad frames, ensure ground pad visible,
///     vent vapor near the engine bells.
///   • Starship: snap container back to OLM y (landing leaves the ship
///     mid-air otherwise), attach/restore the booster, close chopsticks,
///     vent vapor lower since there's no ground pad.
final class RocketOnPadState: RocketBaseState {

    private weak var vaporNode: SKNode?

    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        playOnPadFrames()

        if entity.kind == .starship3 {
            didEnterStarship(from: previousState)
        } else {
            didEnterConventional()
        }

        spawnVaporLoop()
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "onPad")
        vaporNode?.removeAllActions()
        vaporNode?.removeAllChildren()
        vaporNode?.removeFromParent()
        vaporNode = nil
    }

    // MARK: - Conventional rockets

    private func didEnterConventional() {
        entity.ensurePadVisible()
    }

    // MARK: - Starship

    private func didEnterStarship(from previousState: GKState?) {
        // Force container back to OLM y — landing may have left it at the
        // chopstick-catch position, but "on pad" is always on the OLM.
        let olmY = entity.kind.containerInitY
        entity.containerNode.position.y = olmY

        // Booster always fades in over 2s whenever it (re)appears on the OLM
        // — both post-landing and the initial spawn — so the transition reads
        // the same every time.
        entity.restoreBoosterFadeIn()

        if let scene = entity.containerNode.scene as? BuddyScene {
            scene.setChopsticks(open: false)
        }
    }

    // MARK: - Shared

    private func playOnPadFrames() {
        let (frames, fps) = RocketSpriteLoader.frames(for: "onpad", kind: entity.kind)
        // Assign first frame synchronously so the sprite is never caught on
        // the init placeholder texture between state entry and the animate
        // action's first tick.
        if let first = frames.first { entity.node.texture = first }
        if frames.count > 1 {
            let loop = SKAction.repeatForever(
                SKAction.animate(with: frames, timePerFrame: 1.0 / fps)
            )
            entity.node.run(loop, withKey: "onPad")
        }
    }

    // MARK: - Cryogenic vapor (shared, kind-tuned origin)

    private func spawnVaporLoop() {
        let vapor = SKNode()
        vapor.zPosition = -0.5
        entity.containerNode.addChild(vapor)
        vaporNode = vapor

        let spawn = SKAction.run { [weak self, weak vapor] in
            guard let self = self, let vapor = vapor else { return }
            self.emitVaporPuff(into: vapor)
        }
        let cycle = SKAction.sequence([spawn, SKAction.wait(forDuration: 0.18)])
        vapor.run(SKAction.repeatForever(cycle), withKey: "vapor")
    }

    private func emitVaporPuff(into parent: SKNode) {
        let radius = CGFloat.random(in: 2...3.3)
        let puff = SKShapeNode(circleOfRadius: radius)
        puff.fillColor = NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 0.85)
        puff.strokeColor = .clear
        puff.zPosition = 0

        let side: CGFloat = Bool.random() ? -1 : 1
        let startX = side * CGFloat.random(in: 8...14)
        // Starship vents vapor lower (no ground pad beneath the engines).
        let startY: CGFloat = (entity.kind == .starship3)
            ? CGFloat.random(in: -23 ... -16)
            : CGFloat.random(in: -14 ... -8)
        puff.position = CGPoint(x: startX, y: startY)
        parent.addChild(puff)

        let duration = Double.random(in: 1.2...1.8)
        let drift = SKAction.moveBy(x: side * CGFloat.random(in: 1.5...5),
                                     y: CGFloat.random(in: 7...12),
                                     duration: duration)
        let fade = SKAction.fadeOut(withDuration: duration)
        let expand = SKAction.scale(to: 1.35, duration: duration)
        puff.run(SKAction.group([drift, fade, expand])) { [weak puff] in
            puff?.removeFromParent()
        }
    }
}
