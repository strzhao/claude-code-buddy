import Foundation
@testable import BuddyCore

/// Test double for SceneControlling that records all calls for assertion.
final class MockScene: SceneControlling {

    // Recorded calls
    var addCatCalls: [SessionInfo] = []
    var removeCatCalls: [String] = []
    var updateStateCalls: [(sessionId: String, state: CatState, desc: String?)] = []
    var updateLabelCalls: [(sessionId: String, label: String)] = []
    var catPositionCalls: [String] = []
    var spawnFoodCalls: [CGFloat?] = []

    // Stubbed return values
    var stubbedActiveCatCount: Int = 0
    var stubbedCatPositions: [String: CGFloat] = [:]

    // MARK: - SceneControlling

    var activeCatCount: Int { stubbedActiveCatCount }

    func addCat(info: SessionInfo) {
        addCatCalls.append(info)
        stubbedActiveCatCount += 1
    }

    func removeCat(sessionId: String) {
        removeCatCalls.append(sessionId)
        if stubbedActiveCatCount > 0 { stubbedActiveCatCount -= 1 }
    }

    func updateCatState(sessionId: String, state: CatState, toolDescription: String?) {
        updateStateCalls.append((sessionId, state, toolDescription))
    }

    func updateCatLabel(sessionId: String, label: String) {
        updateLabelCalls.append((sessionId, label))
    }

    func catPosition(for sessionId: String) -> CGFloat? {
        catPositionCalls.append(sessionId)
        return stubbedCatPositions[sessionId]
    }

    func spawnFood(near x: CGFloat?) {
        spawnFoodCalls.append(x)
    }

    // Bed slot stubs
    var assignBedSlotCalls: [String] = []
    var releaseBedSlotCalls: [String] = []
    var stubbedBedSlotX: CGFloat? = 800

    func assignBedSlot(for sessionId: String) -> CGFloat? {
        assignBedSlotCalls.append(sessionId)
        return stubbedBedSlotX
    }

    func releaseBedSlot(for sessionId: String) {
        releaseBedSlotCalls.append(sessionId)
    }

    func bedColorName(for sessionId: String) -> String? {
        return "bed-blue"
    }

    // MARK: - Query Support Stubs

    var stubbedCatSnapshots: [String: CatSnapshot] = [:]
    var stubbedAllCatSnapshots: [CatSnapshot] = []
    var stubbedSceneSnapshot = SceneSnapshot(visible: true, catsRendered: 0, boundsMin: 48, boundsMax: 752)

    func catSnapshot(for sessionId: String) -> CatSnapshot? {
        return stubbedCatSnapshots[sessionId]
    }

    func allCatSnapshots() -> [CatSnapshot] {
        return stubbedAllCatSnapshots
    }

    func sceneSnapshot() -> SceneSnapshot {
        return stubbedSceneSnapshot
    }

    // MARK: - Entity API (Step 4)

    var addEntityCalls: [(info: SessionInfo, mode: EntityMode)] = []
    var removeEntityCalls: [String] = []
    var dispatchEventCalls: [(sessionId: String, event: EntityInputEvent)] = []

    var replaceAllCalled = false
    var lastReplacementMode: EntityMode?
    var lastReplacementSessionIds: [String] = []
    var lastReplacementEvents: [String: EntityInputEvent] = [:]
    /// Optional hook to block `replaceAllEntities` until signaled (for queue tests).
    var replaceAllBlock: (() -> Void)?

    func addEntity(info: SessionInfo, mode: EntityMode) {
        addEntityCalls.append((info, mode))
        if mode == .cat { addCat(info: info) } else { stubbedActiveCatCount += 1 }
    }

    func removeEntity(sessionId: String) {
        removeEntityCalls.append(sessionId)
        removeCat(sessionId: sessionId)
    }

    func replaceAllEntities(with mode: EntityMode,
                            infos: [SessionInfo],
                            lastEvents: [String: EntityInputEvent],
                            onOldEntitiesExited: (() -> Void)?,
                            completion: @escaping () -> Void) {
        replaceAllCalled = true
        lastReplacementMode = mode
        lastReplacementSessionIds = infos.map(\.sessionId)
        lastReplacementEvents = lastEvents
        if let block = replaceAllBlock {
            DispatchQueue.global().async {
                block()
                DispatchQueue.main.async {
                    onOldEntitiesExited?()
                    completion()
                }
            }
        } else {
            DispatchQueue.main.async {
                onOldEntitiesExited?()
                completion()
            }
        }
    }

    func dispatchEntityEvent(sessionId: String, event: EntityInputEvent) {
        dispatchEventCalls.append((sessionId, event))
    }
}
