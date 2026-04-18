import GameplayKit
import SpriteKit
import ImageIO

final class CatTaskCompleteState: GKState, ResumableState {

    unowned let entity: CatSprite

    /// The bed sprite node placed in the scene during this state.
    private var bedNode: SKSpriteNode?

    /// The bed sprite name used to create the bed node (stored for hot-swap texture reload).
    private(set) var currentBedName: String?

    /// Whether a bed slot was successfully assigned (prevents releasing unassigned slots).
    private var hasBedSlot = false

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        switch stateClass {
        case is CatIdleState.Type,
             is CatThinkingState.Type,
             is CatToolUseState.Type,
             is CatPermissionRequestState.Type:
            return true
        default:
            return false
        }
    }

    // MARK: - Entry

    override func didEnter(from previousState: GKState?) {
        // Request a bed slot from the scene
        guard let bedInfo = entity.onBedRequested?(entity.sessionId) else {
            // No slot available — defer fallback to next frame to avoid re-entrant state transition
            entity.node.run(SKAction.sequence([
                SKAction.wait(forDuration: 0),
                SKAction.run { [weak self] in
                    guard let self = self, self.stateMachine?.currentState is CatTaskCompleteState else { return }
                    self.stateMachine?.enter(CatIdleState.self)
                }
            ]), withKey: "bedFallback")
            return
        }

        hasBedSlot = true
        let bedX = bedInfo.x
        let bedName = bedInfo.bedName
        currentBedName = bedName

        // Create and place the bed sprite
        let bed = createBedNode(named: bedName)
        bed.position = CGPoint(x: bedX, y: 14)
        entity.containerNode.parent?.addChild(bed)
        bedNode = bed

        // Walk to the bed
        walkToBed(targetX: bedX)
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        // Remove the bed from the scene
        bedNode?.removeFromParent()
        bedNode = nil

        // Release the bed slot only if one was assigned
        if hasBedSlot {
            entity.onBedReleased?(entity.sessionId)
            hasBedSlot = false
        }

        // Clean up all animation keys
        entity.node.removeAction(forKey: "animation")
        entity.node.removeAction(forKey: "breathing")
        entity.node.removeAction(forKey: "bedFallback")
        entity.containerNode.removeAction(forKey: "bedWalk")
    }

    // MARK: - ResumableState

    func resume() {
        // After fright recovery, just keep sleeping on the bed
        startSleepLoop()
    }

    // MARK: - Walk to Bed

    private func walkToBed(targetX: CGFloat) {
        let containerNode = entity.containerNode
        let node = entity.node
        let delta = targetX - containerNode.position.x
        let distance = abs(delta)

        entity.face(towardX: targetX)

        // Play walk animation
        if let frames = entity.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }

        let duration = max(distance / CatConstants.TaskComplete.walkSpeed, 0.3)
        let move = SKAction.moveTo(x: targetX, duration: duration)
        let arrive = SKAction.run { [weak self] in
            guard let self = self, self.stateMachine?.currentState is CatTaskCompleteState else { return }
            self.startSleepLoop()
        }
        containerNode.run(SKAction.sequence([move, arrive]), withKey: "bedWalk")
    }

    // MARK: - Sleep on Bed

    private func startSleepLoop() {
        let node = entity.node

        // Stop walk animation
        node.removeAction(forKey: "animation")

        // Play sleep animation loop
        if let frames = entity.animationComponent.textures(for: "sleep"), !frames.isEmpty {
            let animDuration = 1.0 / Double(frames.count)
            let animate = SKAction.animate(with: frames, timePerFrame: animDuration)
            let loop = SKAction.repeat(animate, count: CatConstants.Idle.sleepLoopCount)
            let wait = SKAction.wait(forDuration: CatConstants.Idle.sleepWaitDuration, withRange: CatConstants.Idle.sleepWaitRange)
            let restart = SKAction.run { [weak self] in
                guard let self = self, self.stateMachine?.currentState is CatTaskCompleteState else { return }
                self.startSleepLoop()
            }
            node.run(SKAction.sequence([loop, wait, restart]), withKey: "animation")
            node.texture = frames[0]
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }

        // Show tab name so user can identify which task completed
        entity.showTabName()
    }

    // MARK: - Bed Node

    private func createBedNode(named name: String) -> SKSpriteNode {
        let renderSize = CatConstants.TaskComplete.bedRenderSize
        let texture = loadBedTexture(named: name)
        let bed = SKSpriteNode(texture: texture, size: renderSize)
        bed.name = "bed_\(entity.sessionId)"
        bed.zPosition = CatConstants.TaskComplete.bedZPosition
        if texture != nil {
            bed.texture?.filteringMode = .nearest
        } else {
            bed.color = .brown
        }
        return bed
    }

    private func loadBedTexture(named name: String) -> SKTexture? {
        let skin = SkinPackManager.shared.activeSkin
        guard let url = skin.url(forResource: name,
                                 withExtension: "png",
                                 subdirectory: skin.manifest.spriteDirectory),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let tex = SKTexture(cgImage: cgImage)
        tex.filteringMode = .nearest
        return tex
    }

    // MARK: - Hot-Swap Support

    /// Reload the bed texture from a new skin pack (called during skin hot-swap).
    func reloadBedTexture(from skin: SkinPack) {
        guard let bedNode = bedNode, let name = currentBedName else { return }
        if let tex = loadBedTexture(named: name) {
            bedNode.texture = tex
        }
    }
}
