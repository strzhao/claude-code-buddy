import SpriteKit

// MARK: - CatConstants
// All magic numbers used in CatSprite and BuddyScene, organized by concern.

enum CatConstants {

    // MARK: - Movement
    enum Movement {
        /// Walk speed range in px/s (random walk)
        static let walkSpeedRange: ClosedRange<Double> = 35...55
        /// Minimum walk duration in seconds
        static let walkMinDuration: Double = 0.3
        /// Max horizontal range from originX for random walk
        static let walkMaxRange: CGFloat = 120
        /// Boundary margin from scene edges during random walk
        static let walkBoundaryMargin: CGFloat = 24
        /// Minimum distance to bother moving (otherwise just pause)
        static let walkMinDistance: CGFloat = 2.0
        /// Pause duration range after arriving at destination
        static let walkPauseRange: ClosedRange<Double> = 1.0...2.5
        /// Probability of taking a brief rest mid-walk (Float for Float.random)
        static let walkRestProbability: Float = 0.15
        /// Duration range of brief rest
        static let walkRestDurationRange: ClosedRange<Double> = 0.8...1.5
        /// Probability of showing paw pose instead of idle-a during standing pause
        static let walkPawProbability: Float = 0.3
        /// Minimum remaining distance after last jump to bother walking to target
        static let walkPostJumpMinDistance: CGFloat = 5
        /// Minimum duration for post-jump remaining walk segment
        static let walkPostJumpMinDuration: Double = 0.2
        /// Delta threshold for updating facing direction
        static let facingDirectionThreshold: CGFloat = 0.5
        /// Walk speed when moving toward food (px/s)
        static let foodWalkSpeed: CGFloat = 55
        /// Minimum food walk duration in seconds
        static let foodWalkMinDuration: Double = 0.3
        /// Walk speed during exit sequence (px/s)
        static let exitWalkSpeed: Double = 120.0
        /// Offset (px) past screen edge to place exit destination
        static let exitOffscreenOffset: CGFloat = 48
        /// Minimum exit walk duration in seconds
        static let exitMinDuration: Double = 0.5
    }

    // MARK: - Jump
    enum Jump {
        /// Tolerance (px) for considering an obstacle "on path" for general-purpose jump
        static let obstaclePathTolerance: CGFloat = 24
        /// Walk speed during approach to obstacle (px/s)
        static let approachWalkSpeed: Double = 120.0
        /// Minimum approach walk duration in seconds (general-purpose jump)
        static let approachMinDuration: Double = 0.15
        /// Minimum approach walk duration in seconds (exit jump)
        static let approachMinDurationExit: Double = 0.2
    }

    // MARK: - PhysicsJump
    enum PhysicsJump {
        // --- Trajectory ---
        /// Custom "jump gravity" in px/s². 800 produces snappy arcs.
        /// Window height is 80px, groundY=48, so safe peak ≈ 25px.
        /// h = v₀y² / (2g), so h=12→v₀y=140, h=25→v₀y=200.
        static let gravity: CGFloat = 800
        /// Range of initial upward velocity (px/s). Produces peak heights of 12-25px.
        static let velocityYRange: ClosedRange<CGFloat> = 140...200
        /// Range of horizontal velocity (px/s) during the arc.
        static let velocityXRange: ClosedRange<CGFloat> = 280...500
        /// Range of approach offset before/after obstacle (px), randomized per jump.
        static let approachOffsetRange: ClosedRange<CGFloat> = 15...30

        // --- Crouch Animation ---
        /// ScaleY during crouch (compression before jump).
        static let crouchScaleY: CGFloat = 0.65
        /// Duration range for crouch animation (seconds).
        static let crouchDurationRange: ClosedRange<Double> = 0.08...0.20

        // --- Launch Animation ---
        /// ScaleY at launch moment (brief stretch upward).
        static let launchStretchScaleY: CGFloat = 1.3
        /// Duration of launch stretch (seconds).
        static let launchStretchDuration: Double = 0.06

        // --- Air Stretch ---
        /// Maximum additional scaleY during flight based on vertical velocity fraction.
        static let airStretchMaxScaleY: CGFloat = 1.15
        /// Maximum scaleX squeeze during flight (1.0 - squeeze).
        static let airStretchSqueezeScaleX: CGFloat = 0.88

        // --- Landing Animation ---
        /// Landing squash scaleX (widening).
        static let landingSquashScaleX: CGFloat = 1.3
        /// Landing squash scaleY (compression).
        static let landingSquashScaleY: CGFloat = 0.6
        /// Duration of landing squash hold (seconds).
        static let landingSquashDuration: Double = 0.08
        /// Duration of landing recovery back to 1.0 scale (seconds).
        static let landingRecoveryDuration: Double = 0.15

        // --- Dust Particles ---
        /// Number of dust particles spawned at landing.
        static let dustParticleCount: Int = 6
        /// Range of dust particle sizes (px).
        static let dustParticleSizeRange: ClosedRange<CGFloat> = 2...4
        /// Range of dust particle initial velocity (px/s).
        static let dustVelocityRange: ClosedRange<CGFloat> = 30...80
        /// Duration of dust particle fade-out (seconds).
        static let dustFadeDuration: Double = 0.4
        /// Alpha for dust particles.
        static let dustAlpha: CGFloat = 0.4

        // --- Apex / Bounds ---
        /// Fraction of total flight time at which to fire onJumpOver callback.
        static let apexCallbackFraction: Double = 0.45
        /// Minimum horizontal clearance from activity boundary for landing prediction.
        static let boundsClearance: CGFloat = 10
        /// GCD fallback delay fraction for mid-arc position.
        static let gcdFallbackFraction: Double = 0.4
    }

    // MARK: - Animation
    enum Animation {
        /// Frame duration for blink animation
        static let frameTimeBlink: TimeInterval = 0.12
        /// Frame duration for jump transition animation
        static let frameTimeJump: TimeInterval = 0.12
        /// Frame duration for clean animation (transition)
        static let frameTimeClean: TimeInterval = 0.15
        /// Frame duration for paw animation
        static let frameTimePaw: TimeInterval = 0.18
        /// Frame duration for scared animation
        static let frameTimeScared: TimeInterval = 0.12
        /// Frame duration for walk animation
        static let frameTimeWalk: TimeInterval = 0.10
        /// Frame duration for exit walk animation
        static let frameTimeExitWalk: TimeInterval = 0.12
        /// Frame duration for standing/idle-a animation during pause
        static let frameTimeStand: TimeInterval = 0.25
        /// Frame duration for idle-a loop animation
        static let frameTimeIdleA: TimeInterval = 0.20
        /// Frame duration for jump-over arc animation
        static let frameTimeJumpOver: TimeInterval = 0.10
        /// Duration of one sway direction (thinking state)
        static let swayDuration: TimeInterval = 0.6
        /// Sway rotation angle (thinking state) in radians
        static let swayAngle: CGFloat = .pi / 60
        /// Max Y scale during breathing animation
        static let breatheScaleY: CGFloat = 1.02
        /// Duration of one breathing phase (in or out)
        static let breatheDuration: TimeInterval = 1.0
        /// Duration of one bounce scale pulse phase (permission-request state)
        static let bounceDuration: TimeInterval = 0.175
        /// Max Y scale during bounce pulse
        static let bounceScaleY: CGFloat = 1.15
        /// Shake horizontal delta in px
        static let shakeDeltaX: CGFloat = 3
        /// Duration of one shake segment
        static let shakeDuration: TimeInterval = 0.04
        /// Duration of badge fade in/out pulse
        static let badgeFadeDuration: TimeInterval = 0.25
        /// Minimum alpha of badge during pulse
        static let badgePulseMinAlpha: CGFloat = 0.3
    }

    // MARK: - Physics
    enum Physics {
        /// Physics body size for collision detection
        static let bodySize = CGSize(width: 44, height: 44)
        /// Restitution (bounciness) of cat physics body
        static let restitution: CGFloat = 0.0
        /// Friction of cat physics body
        static let friction: CGFloat = 0.8
        /// Linear damping of cat physics body
        static let linearDamping: CGFloat = 0.5
        /// Placeholder sprite size used in init
        static let placeholderSize = CGSize(width: 48, height: 48)
    }

    // MARK: - Fright
    enum Fright {
        /// Distance to flee in px when frightened
        static let fleeDistance: CGFloat = 30
        /// Boundary margin from scene edges when clamping flee target
        static let boundaryMargin: CGFloat = 24
        /// Rebound factor: fraction of slide delta to spring back
        static let reboundFactor: CGFloat = 0.5
        /// Duration of the slide-away movement
        static let slideDuration: TimeInterval = 0.15
        /// Duration of the rebound movement
        static let reboundDuration: TimeInterval = 0.12
        /// GCD fallback initial offset before triggering slide
        static let gcdInitialOffset: Double = 0.01
        /// GCD fallback settle offset (added after scared + slide + rebound)
        static let gcdSettleOffset: Double = 0.01
    }

    // MARK: - Idle
    enum Idle {
        /// Cumulative probability threshold for sleep sub-state (Float for Float.random)
        static let sleepWeight: Float = 0.70
        /// Cumulative probability threshold for breathe sub-state
        static let breatheWeightCumulative: Float = 0.80
        /// Cumulative probability threshold for blink sub-state
        static let blinkWeightCumulative: Float = 0.90
        /// How many times to loop the sleep animation before pausing
        static let sleepLoopCount: Int = 3
        /// Base duration (seconds) to wait between sleep loops
        static let sleepWaitDuration: TimeInterval = 5
        /// Random range added to sleepWaitDuration
        static let sleepWaitRange: TimeInterval = 2
        /// Base duration (seconds) to show breathe animation before transitioning
        static let breatheWaitDuration: TimeInterval = 4
        /// Random range added to breatheWaitDuration
        static let breatheWaitRange: TimeInterval = 2
        /// Total duration spread over blink animation frames
        static let blinkAnimDuration: Double = 2.0
        /// Total duration spread over clean animation frames
        static let cleanAnimDuration: Double = 3.0
    }

    // MARK: - Visual
    enum Visual {
        /// Hitbox size used for mouse hit-testing
        static let hitboxSize = CGSize(width: 48, height: 64)
        /// Scale factor when hovered
        static let hoverScale: CGFloat = 1.25
        /// Duration of hover scale animation
        static let hoverDuration: TimeInterval = 0.15
        /// Color blend factor for session color tint
        static let tintFactor: CGFloat = 0.3
        /// Font size for the session label
        static let labelFontSize: CGFloat = 14
        /// Alpha for label shadow
        static let labelShadowAlpha: CGFloat = 0.4
        /// Position offset for label shadow
        static let labelShadowOffset = CGPoint(x: 1.5, y: 1.5)
        /// Z-position for label shadow node
        static let labelShadowZPosition: CGFloat = 9
        /// Y offset for main label above sprite
        static let labelYOffset: CGFloat = 28
        /// Z-position for main label node
        static let labelZPosition: CGFloat = 10
        /// Font size for the tab name label
        static let tabLabelFontSize: CGFloat = 12
        /// Y position for tab label shadow (waiting state)
        static let tabLabelShadowYOffset: CGFloat = 17
        /// Y position for tab label (waiting state)
        static let tabLabelYOffset: CGFloat = 18
        /// Maximum characters for tool description label before truncation
        static let labelMaxLength: Int = 80
        /// Overlay color for permission-request state
        static let permissionColor = NSColor(red: 1, green: 0.3, blue: 0, alpha: 1)
        /// Color blend factor for permission-request state
        static let permissionBlendFactor: CGFloat = 0.55
        /// Shadow label color for permission-request state
        static let permissionLabelShadowColor = NSColor(white: 0, alpha: 0.6)
        /// Z-position for the alert overlay node
        static let alertOverlayZPosition: CGFloat = 15
        /// Approximate character width (pt) used to estimate label half-width for badge placement
        static let alertBadgeCharWidth: CGFloat = 4.5
        /// Horizontal padding from label edge to badge center
        static let alertBadgeHPadding: CGFloat = 16
        /// Radius of alert badge circle
        static let alertBadgeRadius: CGFloat = 10
        /// Fill color of the alert badge
        static let alertBadgeColor = NSColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1)
        /// Line width of alert badge stroke
        static let alertBadgeLineWidth: CGFloat = 1.5
        /// Y offset for alert badge above baseline
        static let alertBadgeYOffset: CGFloat = 40
        /// Font size for the "!" label in the alert badge
        static let alertBadgeFontSize: CGFloat = 15
        /// Y position of ground level in scene coordinates
        static let groundY: CGFloat = 48
        /// Minimum horizontal margin from scene edge for cat spawn
        static let spawnMargin: CGFloat = 48
    }

    // MARK: - Scene (shared with BuddyScene)
    enum Scene {
        /// Gravity dy value for the physics world
        static let gravity: Double = -9.8
        /// Friction for the ground physics body
        static let groundFriction: CGFloat = 0.5
        /// Maximum number of cats on screen at once
        static let maxCats: Int = 8
    }

    // MARK: - TaskComplete
    enum TaskComplete {
        /// Render size for the bed sprite in the scene
        static let bedRenderSize = CGSize(width: 48, height: 28)
        /// Walk speed toward the bed in px/s
        static let walkSpeed: Double = 55
        /// Horizontal offset from activityBounds.upperBound for first bed slot (negative = left of boundary)
        static let firstSlotOffset: CGFloat = -60
        /// Horizontal spacing between bed slots (negative = extend leftward)
        static let slotSpacing: CGFloat = -56
        /// Maximum number of bed slots
        static let maxSlots: Int = 4
        /// Z-position for the bed sprite (in front of cat so cat appears to sit inside)
        static let bedZPosition: CGFloat = -1
    }

    // MARK: - BoundaryRecovery
    enum BoundaryRecovery {
        /// How far outside activity bounds a cat must be before recovery triggers.
        /// Filters minor excursions from fright rebound (max ~15px).
        static let outOfBoundsTolerance: CGFloat = 8
        /// Walk speed when returning to bounds (px/s).
        static let recoveryWalkSpeed: Double = 65
        /// Minimum duration for the recovery walk action.
        static let recoveryMinDuration: Double = 0.3
        /// How long a cat must be continuously out of bounds before recovery triggers.
        static let gracePeriod: TimeInterval = 0.5
        /// Action key for the recovery walk on containerNode.
        static let actionKey = "boundaryRecovery"
    }

    // MARK: - PersistentBadge
    enum PersistentBadge {
        /// Radius of the persistent alert badge circle (smaller than animated badge)
        static let radius: CGFloat = 7
        /// X offset from sprite center for persistent badge position
        static let xOffset: CGFloat = 22
        /// Y offset from sprite center for persistent badge position
        static let yOffset: CGFloat = 38
        /// Duration of one pulse phase (total cycle = 2× this)
        static let pulseDuration: TimeInterval = 0.75
        /// Minimum alpha during pulse
        static let minAlpha: CGFloat = 0.5
        /// Font size for the "!" text in persistent badge
        static let fontSize: CGFloat = 11
        /// Stroke line width for persistent badge circle
        static let lineWidth: CGFloat = 1.0
    }

    // MARK: - Separation
    enum Separation {
        /// Minimum desired X distance between two cat centers (px).
        /// Physics body is 44px, so 52px gives ~8px visual gap.
        static let minDistance: CGFloat = 52
        /// Maximum nudge per frame (px). At 60fps = 30 px/s.
        static let nudgeSpeed: CGFloat = 0.5
        /// Minimum spawn distance from any existing cat (px).
        static let minSpawnDistance: CGFloat = 60
        /// Maximum spawn placement attempts.
        static let maxSpawnAttempts: Int = 10
    }
}
