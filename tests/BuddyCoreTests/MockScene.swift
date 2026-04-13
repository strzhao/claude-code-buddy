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
}
