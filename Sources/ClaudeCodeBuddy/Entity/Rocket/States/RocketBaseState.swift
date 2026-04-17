import GameplayKit

class RocketBaseState: GKState {
    unowned let entity: RocketEntity
    init(entity: RocketEntity) { self.entity = entity }
}
