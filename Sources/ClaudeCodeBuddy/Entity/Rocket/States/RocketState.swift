import Foundation

/// Independent state enum for RocketEntity.
/// Does NOT share identity with CatState — fully decoupled.
enum RocketState: String, CaseIterable {
    case onPad
    case systemsCheck
    case cruising
    case abortStandby
    case propulsiveLanding
    case liftoff
}
