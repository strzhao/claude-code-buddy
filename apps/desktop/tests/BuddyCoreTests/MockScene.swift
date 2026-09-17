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
        onScreenSessionIds.insert(info.sessionId)
        stubbedActiveCatCount += 1
    }

    func removeCat(sessionId: String) {
        removeCatCalls.append(sessionId)
        onScreenSessionIds.remove(sessionId)
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

    /// 与生产 BuddyScene 对齐的「是否在屏」跟踪：addCat/removeCat 维护，
    /// 使 `catSnapshot(for:)` 在未显式 stub 时也反映真实在屏状态
    /// （QueryHandler `onscreen` 字段与红队 S9-P1/S9-P3 断言依赖此语义）。
    private var onScreenSessionIds: Set<String> = []

    func catSnapshot(for sessionId: String) -> CatSnapshot? {
        if let stubbed = stubbedCatSnapshots[sessionId] { return stubbed }
        guard onScreenSessionIds.contains(sessionId) else { return nil }
        return CatSnapshot(
            sessionId: sessionId, x: 0, y: 24, state: "idle", facingRight: true,
            isDebug: sessionId.hasPrefix("debug-"), activityBoundsMin: 48, activityBoundsMax: 752,
            labelText: sessionId, tabName: nil, hasAlertOverlay: false,
            hasPersistentBadge: false, hasUpdateBadge: false, permissionAcknowledged: false)
    }

    func allCatSnapshots() -> [CatSnapshot] {
        return stubbedAllCatSnapshots
    }

    func sceneSnapshot() -> SceneSnapshot {
        return stubbedSceneSnapshot
    }

    var simulateClickCalls: [String] = []
    var stubbedSimulateClickResult = true

    func simulateClick(sessionId: String) -> Bool {
        simulateClickCalls.append(sessionId)
        return stubbedSimulateClickResult
    }
}
