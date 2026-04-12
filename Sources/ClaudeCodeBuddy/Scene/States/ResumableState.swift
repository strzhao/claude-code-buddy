import GameplayKit

/// A GKState subclass that can re-apply its steady-state animation without
/// going through a full state transition. Used by playFrightReaction's
/// recover block to restore the correct animation after the fright animation.
protocol ResumableState: AnyObject {
    func resume()
}
