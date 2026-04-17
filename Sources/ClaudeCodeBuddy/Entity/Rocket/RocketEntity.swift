import SpriteKit
import GameplayKit

/// Rocket-form SessionEntity. Fully decoupled from CatEntity.
/// Phase 1: state visualization only, zero interactions.
final class RocketEntity {

    let sessionId: String
    let containerNode = SKNode()
    let node: SKSpriteNode
    private(set) var sessionColor: SessionColor?
    private(set) var stateMachine: GKStateMachine!

    var currentState: RocketState {
        switch stateMachine?.currentState {
        case is RocketOnPadState:              return .onPad
        case is RocketSystemsCheckState:       return .systemsCheck
        case is RocketCruisingState:           return .cruising
        case is RocketAbortStandbyState:       return .abortStandby
        case is RocketPropulsiveLandingState:  return .propulsiveLanding
        case is RocketLiftoffState:            return .liftoff
        default:                                return .onPad
        }
    }

    init(sessionId: String) {
        self.sessionId = sessionId

        node = SKSpriteNode(texture: RocketSpriteLoader.placeholderTexture(),
                            size: RocketConstants.Visual.spriteSize)
        node.name = "rocketSprite_\(sessionId)"
        containerNode.name = "rocket_\(sessionId)"
        containerNode.addChild(node)

        setupPhysics()

        let states: [GKState] = [
            RocketOnPadState(entity: self),
            RocketSystemsCheckState(entity: self),
            RocketCruisingState(entity: self),
            RocketAbortStandbyState(entity: self),
            RocketPropulsiveLandingState(entity: self),
            RocketLiftoffState(entity: self)
        ]
        stateMachine = GKStateMachine(states: states)
        stateMachine.enter(RocketOnPadState.self)
    }

    private func setupPhysics() {
        let body = SKPhysicsBody(rectangleOf: RocketConstants.Physics.bodySize)
        body.allowsRotation = false
        body.categoryBitMask = PhysicsCategory.cat
        body.collisionBitMask = PhysicsCategory.cat | PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = RocketConstants.Physics.restitution
        body.friction = RocketConstants.Physics.friction
        body.linearDamping = RocketConstants.Physics.linearDamping
        containerNode.physicsBody = body
    }
}

extension RocketEntity: SessionEntity {

    var isDebug: Bool { sessionId.hasPrefix("debug-") }

    func configure(color: SessionColor, labelText: String) {
        sessionColor = color
        node.color = color.nsColor
        node.colorBlendFactor = RocketConstants.Visual.tintFactor
    }

    func updateLabel(_ newLabel: String) {
        // Phase 1 rocket: no-op label
    }

    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?) {
        containerNode.position = CGPoint(x: containerNode.position.x,
                                         y: RocketConstants.Visual.groundY)
        stateMachine.enter(RocketOnPadState.self)
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        let fade = SKAction.fadeOut(withDuration: 0.2)
        let done = SKAction.run { completion() }
        containerNode.run(SKAction.sequence([fade, done]))
    }

    func updateSceneSize(_ size: CGSize) {
        // Rocket phase 1 doesn't care
    }

    func applyHoverScale() {
        node.setScale(1.1)
    }

    func removeHoverScale() {
        node.setScale(1.0)
    }

    func handle(event: EntityInputEvent) {
        switch event {
        case .sessionStart:            stateMachine.enter(RocketOnPadState.self)
        case .thinking:                stateMachine.enter(RocketSystemsCheckState.self)
        case .toolStart:               stateMachine.enter(RocketCruisingState.self)
        case .toolEnd:                 stateMachine.enter(RocketOnPadState.self)
        case .permissionRequest:       stateMachine.enter(RocketAbortStandbyState.self)
        case .taskComplete:            stateMachine.enter(RocketPropulsiveLandingState.self)
        case .sessionEnd:              stateMachine.enter(RocketLiftoffState.self)
        case .hoverEnter:              applyHoverScale()
        case .hoverExit:               removeHoverScale()
        case .externalCommand:         break
        }
    }
}
