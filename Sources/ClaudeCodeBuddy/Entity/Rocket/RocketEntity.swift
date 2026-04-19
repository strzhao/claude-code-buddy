import SpriteKit
import GameplayKit

/// Rocket-form SessionEntity. Fully decoupled from CatEntity.
/// Phase 1: state visualization only, zero interactions.
final class RocketEntity {

    let sessionId: String
    let kind: RocketKind
    let containerNode = SKNode()
    let node: SKSpriteNode
    /// Separate pad sprite added to the scene alongside the rocket. Stays put horizontally
    /// while the rocket drifts — gives the visual impression that the rocket lifts off the
    /// pad (rather than dragging the pad with it). States appear/hide it.
    let padNode: SKSpriteNode
    /// Super Heavy booster, for Starship 3 only. Drawn beneath the ship while
    /// on pad, procedurally detached and tumbled off-screen during liftoff,
    /// faded back in after a successful landing. `nil` for all other kinds.
    private(set) var boosterNode: SKSpriteNode?
    /// Scene-level flame plume used during liftoff phase 2. Lives BEHIND the
    /// OLM (z=-0.3 vs OLM's -0.2) so the OLM's pillars cover parts of it and
    /// the flame "leaks" through the vent gaps — the whole point of the OLM
    /// truss. Created by `igniteBoosterFlame`, removed at separation.
    private var boosterFlameNode: SKNode?
    private(set) var sessionColor: SessionColor?
    private(set) var stateMachine: GKStateMachine!

    /// Horizontal activity range (scene-local). Cruising state clamps to this.
    /// Defaults to a generic range; real value is injected via enterScene / updateActivityBounds.
    var activityBounds: ClosedRange<CGFloat> = 48...752

    /// Scene-Y where this rocket's pad sprite is centered. Bottom of pad
    /// sprite aligns with y=0, so center sits at half-height.
    var padVisibleY: CGFloat { kind.spriteSize.height / 2 }

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

    /// Once the rocket is cruising, tool_end / repeated thinking shouldn't yank it
    /// back to the pad. Only propulsiveLanding / liftoff end the flight cleanly.
    var isInFlight: Bool {
        let s = currentState
        return s == .cruising || s == .propulsiveLanding || s == .liftoff
    }

    init(sessionId: String, kind: RocketKind = .classic) {
        self.sessionId = sessionId
        self.kind = kind

        node = SKSpriteNode(texture: RocketSpriteLoader.placeholderTexture(size: kind.spriteSize),
                            size: kind.spriteSize)
        node.name = "rocketSprite_\(sessionId)"
        containerNode.name = "rocket_\(sessionId)"
        containerNode.addChild(node)

        // Pad texture per-kind — F9 uses a thin white mobile launch table.
        let padFrames = RocketSpriteLoader.frames(for: "pad", kind: kind).frames
        let padTex = padFrames.first ?? RocketSpriteLoader.placeholderTexture(size: kind.spriteSize)
        padNode = SKSpriteNode(texture: padTex, size: kind.spriteSize)
        padNode.name = "rocketPad_\(sessionId)"
        padNode.zPosition = -0.1  // behind rocket body
        // Starship relies on the Mechazilla tower, no ground pad needed.
        if !kind.usesGroundPad {
            padNode.isHidden = true
        }

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
        // NOTE: deliberately NOT calling stateMachine.enter here — OnPad's
        // didEnter runs booster fade-in and other scene-dependent setup that
        // only makes sense once the entity is in the scene graph. enterScene()
        // transitions us into OnPad at the right moment.
    }

    private func setupPhysics() {
        // Rockets don't participate in physics: motion is driven entirely by SKActions,
        // bounds are enforced by activityBounds clamping. Static body with no collision
        // so rockets never push each other or react to gravity.
        let body = SKPhysicsBody(rectangleOf: RocketConstants.Physics.bodySize)
        body.isDynamic = false
        body.allowsRotation = false
        body.categoryBitMask = 0
        body.collisionBitMask = 0
        body.contactTestBitMask = 0
        containerNode.physicsBody = body
    }
}

extension RocketEntity: SessionEntity {

    var isDebug: Bool { sessionId.hasPrefix("debug-") }

    func configure(color: SessionColor, labelText: String) {
        sessionColor = color
        // Starship uses real SpaceX stainless steel — do NOT tint by session
        // color (which would hue-shift the hull pink/violet/etc.). Other
        // rocket kinds keep the per-session tint for visual variety.
        if kind == .starship3 {
            node.colorBlendFactor = 0
        } else {
            node.color = color.nsColor
            node.colorBlendFactor = RocketConstants.Visual.tintFactor
        }
    }

    func updateLabel(_ newLabel: String) {
        // Phase 1 rocket: no-op label
    }

    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?) {
        if let bounds = activityBounds { self.activityBounds = bounds }
        containerNode.position = CGPoint(x: containerNode.position.x,
                                         y: kind.containerInitY)
        stateMachine.enter(RocketOnPadState.self)

        // Fade in the sprite + pad so mode-switch appearance feels smooth
        // rather than a hard pop. Short enough to stay snappy.
        let fadeDuration: TimeInterval = 0.35
        containerNode.alpha = 0
        containerNode.run(SKAction.fadeIn(withDuration: fadeDuration))
        if !padNode.isHidden {
            padNode.alpha = 0
            padNode.run(SKAction.fadeIn(withDuration: fadeDuration))
        }
    }

    /// Called by BuddyScene when the Dock/screen changes mid-session.
    func updateActivityBounds(_ bounds: ClosedRange<CGFloat>) {
        activityBounds = bounds
        // Clamp current position to new bounds
        let x = containerNode.position.x
        if x < bounds.lowerBound || x > bounds.upperBound {
            containerNode.position.x = min(max(x, bounds.lowerBound), bounds.upperBound)
        }
    }

    // MARK: - Pad helpers
    //
    // Pad and rocket should leave / rejoin their contact plane (scene y=0) at identical
    // magnitudes, so the two motions look like opposite halves of the same separation.
    // Rocket rises by Δ → pad drops by Δ (same duration, same curve). Same for landing.

    /// Drops the pad from its current y by `delta` points, with the given duration/curve.
    /// Use `delta == rocket's rise magnitude` so pad and rocket look paired.
    func slidePadDown(by delta: CGFloat,
                      duration: TimeInterval,
                      curve: SKActionTimingFunction? = nil) {
        guard kind.usesGroundPad else { return }
        padNode.removeAllActions()
        let targetY = padNode.position.y - delta
        let move = SKAction.moveTo(y: targetY, duration: duration)
        if let curve = curve { move.timingFunction = curve }
        padNode.run(SKAction.sequence([
            move,
            SKAction.run { [weak padNode] in padNode?.isHidden = true }
        ]))
    }

    /// Where the pad "sits" — includes the kind-specific y offset so scaled
    /// rockets (Starship) don't sink their pad below the scene.
    private var padTopY: CGFloat { padVisibleY + (kind.containerInitY - RocketConstants.Visual.groundY) }

    /// Rises the pad from `padTopY - delta` (below scene) up to `padTopY`.
    /// Use `delta == rocket's descent magnitude` so pad and rocket rendezvous in sync.
    func slidePadUp(by delta: CGFloat,
                    duration: TimeInterval,
                    curve: SKActionTimingFunction? = nil) {
        guard kind.usesGroundPad else { return }
        padNode.removeAllActions()
        padNode.position = CGPoint(x: containerNode.position.x,
                                    y: padTopY - delta)
        padNode.isHidden = false
        let move = SKAction.moveTo(y: padTopY, duration: duration)
        if let curve = curve { move.timingFunction = curve }
        padNode.run(move)
    }

    /// Snaps pad to the visible ground without animation. Used on state entries where
    /// the rocket is already landed / idle (OnPad, Systems).
    func ensurePadVisible() {
        guard kind.usesGroundPad else {
            padNode.isHidden = true   // Starship uses Mechazilla, no ground pad
            return
        }
        padNode.removeAllActions()
        padNode.position = CGPoint(x: containerNode.position.x, y: padTopY)
        padNode.isHidden = false
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        // Hot-switch exit: every rocket — regardless of current state
        // (onPad / cruising / abort / landing / liftoff) — takes off
        // straight up and out of the scene. Abandons any in-flight state
        // actions and tears down scene-level dressing (OLM flame, booster
        // separation tumble, chopstick animation) so the sprite leaves
        // cleanly.

        // 1) Cancel all current-state animations on ship + container + pad.
        containerNode.removeAllActions()
        node.removeAllActions()
        padNode.removeAllActions()

        // 2) Starship dressing cleanup — extinguish the scene-level flame
        //    plume and the embedded booster-flame texture before lifting.
        if kind == .starship3 {
            setBoosterIgnited(false)
            boosterNode?.removeAllActions()
            // Let the scene swing chopsticks shut so the right tower
            // doesn't freeze mid-animation.
            (containerNode.scene as? BuddyScene)?.setChopsticks(open: false)
        }

        // 3) Liftoff escape — move up past the top of whatever scene we're
        //    in (sceneHeight isn't directly exposed; use a generous 200pt
        //    which clears any current Dock-window expansion). Speed matches
        //    Starship's OLM-approach cadence (landingApproachSpeed pt/s +
        //    landingApproachMinDuration floor) so rocket-mode exits read as
        //    "flying away" rather than a snap.
        let ascentDistance: CGFloat = 200
        let ascentDuration: TimeInterval = max(
            RocketConstants.Starship.landingApproachMinDuration,
            Double(ascentDistance / RocketConstants.Starship.landingApproachSpeed)
        )
        let ascend = SKAction.moveBy(x: 0, y: ascentDistance, duration: ascentDuration)
        ascend.timingMode = .easeIn

        // 4) Fade during the last 0.4s so the sprite disappears off-screen
        //    instead of popping out.
        let fadeTail: TimeInterval = 0.4
        let fade = SKAction.sequence([
            SKAction.wait(forDuration: max(0, ascentDuration - fadeTail)),
            SKAction.fadeOut(withDuration: fadeTail)
        ])

        let done = SKAction.run { completion() }
        containerNode.run(SKAction.sequence([
            SKAction.group([ascend, fade]),
            done
        ]), withKey: "hotSwitchExit")

        // Pad sprite stays behind — the scene ground is unchanged — so
        // fade it out concurrently to avoid orphaned art.
        padNode.run(SKAction.fadeOut(withDuration: fadeTail))
    }

    func updateSceneSize(_ size: CGSize) {
        // Rocket phase 1 doesn't care
    }

    /// Rocket intentionally doesn't scale on hover — the tooltip label above is enough
    /// feedback, and scaling would disturb the pad alignment.
    func applyHoverScale() { /* no-op */ }
    func removeHoverScale() { /* no-op */ }

    func handle(event: EntityInputEvent) {
        switch event {
        case .sessionStart:
            stateMachine.enter(RocketOnPadState.self)

        case .userPromptSubmit:
            // The user kicking off a new turn is the one and only takeoff trigger.
            // Abort is a "waiting for user" state — if the user's new prompt itself
            // is the answer, we still treat it as approval and resume flight.
            if currentState == .abortStandby {
                stateMachine.enter(RocketCruisingState.self)
            } else if !isInFlight {
                stateMachine.enter(RocketCruisingState.self)
            }

        case .thinking:
            // `.thinking` now comes from Claude's Notification hook (e.g. session
            // went idle, waiting-for-user prompt). It's NOT a new-turn signal, so
            // rocket ignores it entirely — no takeoff, no abort dismissal.
            break

        case .toolStart:
            // Tool running is not a takeoff signal — only .userPromptSubmit lifts
            // the rocket off the pad, so every turn tracks "user started talking"
            // rather than Claude's internal tool churn. The one exception: if we're
            // currently in abortStandby, a tool running implies the user approved the
            // pending permission request, so resume flight.
            if currentState == .abortStandby {
                stateMachine.enter(RocketCruisingState.self)
            }

        case .toolEnd:
            // Tool finished but task not complete yet — stay in the air.
            break

        case .permissionRequest:
            stateMachine.enter(RocketAbortStandbyState.self)

        case .taskComplete:
            stateMachine.enter(RocketPropulsiveLandingState.self)

        case .sessionEnd:
            stateMachine.enter(RocketLiftoffState.self)

        case .hoverEnter:
            applyHoverScale()

        case .hoverExit:
            removeHoverScale()

        case .externalCommand:
            break
        }
    }
}

// MARK: - Starship 3 booster (Super Heavy)
//
// The booster lives as a sibling of the main rocket sprite inside containerNode.
// At spawn/landing it sits beneath the ship. At liftoff we detach and tumble it
// off-screen diagonally; cruise/landing then show only the ship upper stage.

extension RocketEntity {

    /// Attaches the booster sprite beneath the ship (inside containerNode).
    /// Safe to call multiple times — a no-op when kind != .starship3 or when
    /// the booster is already present.
    func attachBoosterIfNeeded() {
        guard kind == .starship3 else { return }
        if let existing = boosterNode, existing.parent != nil {
            existing.isHidden = false
            existing.alpha = 1.0
            // Reset to rest pose (no flame) — in case the booster was ignited
            // during the prior liftoff and the ship is being re-stacked.
            if let rest = RocketSpriteLoader.frames(for: "booster", kind: kind).frames.first {
                existing.texture = rest
            }
            return
        }
        let (boosterFrames, _) = RocketSpriteLoader.frames(for: "booster", kind: kind)
        // Frame[0] = body only (rest / fall). Frame[1] = body + flame (liftoff).
        let tex = boosterFrames.first ?? RocketSpriteLoader.placeholderTexture()
        let booster = SKSpriteNode(texture: tex, size: kind.spriteSize)
        booster.name = "rocketBooster_\(sessionId)"
        booster.zPosition = -0.05              // behind ship, above pad
        booster.position = .zero               // co-located with ship in container coords
        containerNode.addChild(booster)
        boosterNode = booster
    }

    /// Toggles the Super Heavy's engine flame — both the sprite-embedded
    /// flame (booster _b vs _a) AND a scene-level plume that extends BELOW
    /// the sprite canvas through the OLM vents. Used at liftoff phase 2
    /// (ignite on) and at the separation instant (cut off). No-op for
    /// non-Starship kinds.
    func setBoosterIgnited(_ ignited: Bool) {
        guard kind == .starship3 else { return }
        // In-sprite flame (the part visible ABOVE the OLM top, at scene y ≥ 5).
        if let booster = boosterNode {
            let frames = RocketSpriteLoader.frames(for: "booster", kind: kind).frames
            if frames.count >= 2 {
                booster.texture = ignited ? frames[1] : frames[0]
            }
        }
        // Scene-level plume — the part visible AT and BELOW the OLM top.
        if ignited {
            igniteBoosterFlame()
        } else {
            extinguishBoosterFlame()
        }
    }

    private func igniteBoosterFlame() {
        guard kind == .starship3,
              boosterFlameNode?.parent == nil,
              let scene = containerNode.scene else { return }

        let flame = SKNode()
        flame.name = "boosterFlame_\(sessionId)"
        flame.zPosition = -0.3  // behind OLM (-0.2) — OLM pillars overlay flame

        // Three stacked colored rects — red outer glow, orange mid plume,
        // bright yellow/white core. Outer width ≈ 18pt, ~1.5× the booster
        // body (~12pt) per spec. Plume spans scene y≈0 to y≈8 (covers the
        // OLM height with a small flare above the deck).
        let red = SKSpriteNode(color: NSColor(red: 1.0, green: 0.30, blue: 0.18, alpha: 1.0),
                               size: CGSize(width: 18, height: 6))
        red.position = .zero
        flame.addChild(red)

        let orange = SKSpriteNode(color: NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1.0),
                                  size: CGSize(width: 12, height: 7))
        orange.position = CGPoint(x: 0, y: 1)
        flame.addChild(orange)

        let core = SKSpriteNode(color: NSColor(red: 1.0, green: 0.95, blue: 0.65, alpha: 1.0),
                                size: CGSize(width: 4, height: 8))
        core.position = CGPoint(x: 0, y: 1)
        flame.addChild(core)

        // Subtle vertical jitter so the plume looks alive, not static.
        let pulse = SKAction.repeatForever(SKAction.sequence([
            SKAction.scaleY(to: 1.08, duration: 0.08),
            SKAction.scaleY(to: 0.94, duration: 0.08)
        ]))
        flame.run(pulse)

        // Center the plume vertically around scene y=3 (middle of OLM). The
        // x starts matched to the booster — Cruising's phase-2 lateral move
        // mirrors its motion via `moveBoosterFlame(by:duration:)`.
        flame.position = CGPoint(x: containerNode.position.x, y: 3)
        scene.addChild(flame)
        boosterFlameNode = flame
    }

    /// Mirrors the container's lateral move onto the scene-level flame node
    /// so the plume visibly slides out of the OLM alongside the booster.
    func moveBoosterFlame(by dx: CGFloat, duration: TimeInterval) {
        guard let flame = boosterFlameNode else { return }
        let move = SKAction.moveBy(x: dx, y: 0, duration: duration)
        move.timingMode = .linear
        flame.run(move, withKey: "flameLateral")
    }

    private func extinguishBoosterFlame() {
        boosterFlameNode?.removeAllActions()
        boosterFlameNode?.removeFromParent()
        boosterFlameNode = nil
    }

    /// Free-falls the booster straight down with a slight linear tilt, then
    /// removes it. Called from CruisingState when the ship lifts off.
    /// Physics-style: NO tumbling — real Super Heavy does not pinwheel after
    /// stage separation.
    func separateBooster() {
        guard kind == .starship3, let booster = boosterNode, booster.parent != nil else {
            return
        }
        // Reparent from container → scene so the booster can fall on its own
        // trajectory while the ship keeps drifting.
        if let scene = containerNode.scene, booster.parent !== scene {
            let worldPos = booster.parent!.convert(booster.position, to: scene)
            // Preserve world scale: container may be scaled (Starship 1.5×).
            let parentScale = (booster.parent as? SKNode)?.xScale ?? 1.0
            booster.removeFromParent()
            booster.position = worldPos
            booster.setScale(parentScale)
            scene.addChild(booster)
        }
        let fallDistance = RocketConstants.Starship.boosterSeparationDistance
        let dur = RocketConstants.Starship.boosterSeparationDuration

        // Straight-down free fall — linear motion (constant velocity is fine
        // for a short visual beat; real g would accelerate but at this scene
        // scale the difference is imperceptible and linear reads cleaner).
        let fall = SKAction.moveBy(x: 0, y: -fallDistance, duration: dur)
        fall.timingMode = .linear

        // Slight tilt — random direction, ~12°, linear (small angle).
        let tiltSign: CGFloat = Bool.random() ? -1 : 1
        let tiltAngle: CGFloat = tiltSign * (.pi / 15)   // 12°
        let tilt = SKAction.rotate(byAngle: tiltAngle, duration: dur)
        tilt.timingMode = .linear

        let fade = SKAction.sequence([
            SKAction.wait(forDuration: dur * 0.6),
            SKAction.fadeOut(withDuration: dur * 0.4)
        ])
        let remove = SKAction.run { [weak self, weak booster] in
            booster?.removeFromParent()
            if self?.boosterNode === booster { self?.boosterNode = nil }
        }
        booster.run(SKAction.sequence([
            SKAction.group([fall, tilt, fade]),
            remove
        ]), withKey: "boosterSeparation")
    }

    /// Fades the booster back in beneath the landed ship so the pad displays a
    /// full stack again. Called from OnPadState when we enter from
    /// PropulsiveLandingState with kind == .starship3.
    func restoreBoosterFadeIn() {
        guard kind == .starship3 else { return }
        attachBoosterIfNeeded()
        guard let booster = boosterNode else { return }
        // Replace any in-flight separation / fade action — ensures a clean
        // 0 → 1 tween over the restore duration even when restoreBoosterFadeIn
        // fires more than once in quick succession (e.g. state-machine re-entry).
        booster.removeAllActions()
        booster.alpha = 0
        booster.position = .zero
        booster.zRotation = 0
        let fade = SKAction.fadeIn(withDuration: RocketConstants.Starship.boosterRestoreDuration)
        booster.run(fade, withKey: "boosterFadeIn")
    }
}
