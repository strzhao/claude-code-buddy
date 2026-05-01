import Foundation
import SpriteKit

class FoodManager {

    weak var scene: BuddyScene?
    private var activeFoods: [FoodSprite] = []
    private var lastSpawnTime: TimeInterval = 0
    private var idleCheckTimer: Timer?
    private var expirationTimer: Timer?
    private var idleStartTimes: [String: Date] = [:]
    /// Activity bounds for food spawn X positioning. If nil, uses full scene width.
    var activityBounds: ClosedRange<CGFloat>?

    // Config
    static let maxConcurrentFoods = 3
    static let toolEndSpawnProbability: Float = 0.35
    static let minSpawnInterval: TimeInterval = 8.0
    static let idleThresholdForFood: TimeInterval = 45.0

    func start() {
        // Check for expired food every 15 seconds
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkExpirations()
        }
        // Check for idle cats every 30 seconds
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdleCats()
        }
    }

    func stop() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    deinit { stop() }

    // MARK: - Spawn

    func trySpawnFood(near x: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        guard activeFoods.count < Self.maxConcurrentFoods,
              now - lastSpawnTime >= Self.minSpawnInterval else { return }
        lastSpawnTime = now
        spawnFood(near: x)
    }

    private func spawnFood(near targetX: CGFloat?) {
        guard let scene = scene else { return }
        let foodName = FoodSprite.randomFoodName()
        let food = FoodSprite(textureName: foodName)

        // Position: within activity bounds (or full scene width fallback)
        let bounds = activityBounds ?? 32...(scene.size.width - 32)
        let x: CGFloat
        if let targetX = targetX {
            let jittered = targetX + CGFloat.random(in: -40...40)
            x = max(bounds.lowerBound, min(bounds.upperBound, jittered))
        } else {
            x = CGFloat.random(in: bounds)
        }
        food.node.position = CGPoint(x: x, y: scene.size.height + 24)

        scene.addChild(food.node)
        activeFoods.append(food)
    }

    // MARK: - Food Landed

    func foodLanded(_ food: FoodSprite) {
        guard food.state == .falling else { return }
        food.markLanded()
        notifyIdleCats(about: food)
    }

    func food(for node: SKNode) -> FoodSprite? {
        activeFoods.first { $0.node === node }
    }

    // MARK: - Cat Notification

    private func notifyIdleCats(about food: FoodSprite) {
        guard let scene = scene else { return }
        let eligibleCats = scene.foodEligibleCats().filter { $0.currentTargetFood == nil }
        guard !eligibleCats.isEmpty else { return }
        let maxDistance = CatConstants.Movement.maxFoodNoticeDistance
        let foodX = food.node.position.x

        // Only notify the nearest cat within range, not all cats.
        // Broadcasting to all cats pulls them to the same spot, creating
        // the right-edge cluster that triggered this fix.
        var best: (cat: CatSprite, distance: CGFloat)?
        for cat in eligibleCats {
            let distance = abs(foodX - cat.containerNode.position.x)
            if distance <= maxDistance && (best.map({ distance < $0.distance }) ?? true) {
                best = (cat, distance)
            }
        }
        guard let (nearestCat, nearestDist) = best else { return }

        let delay = Double(nearestDist / maxDistance) * 0.3
#if DEBUG
        print("[FOOD] notifyIdleCats: food at x=\(foodX) nearest=\(nearestCat.sessionId) dist=\(nearestDist) among \(eligibleCats.count) eligible")
#endif
        nearestCat.walkToFood(food, excitedDelay: delay) { [weak self] arrivingCat, food in
                guard let self = self else { return }
                guard food.claim(by: arrivingCat.sessionId) else {
                    // Food already claimed — play disappointed reaction instead of snapping to idle
                    arrivingCat.playDisappointedReaction()
                    return
                }
                arrivingCat.startEating(food) {
                    food.eat { [weak self] in
                        self?.removeFood(food)
                    }
                }
            }
    }

    // MARK: - Release Food

    func releaseFoodForCat(sessionId: String) {
        for food in activeFoods where food.claimedBy == sessionId && food.state == .claimed {
            food.release()
            // Re-notify idle cats about this released food
            notifyIdleCats(about: food)
        }
    }

    // MARK: - Notify Single Cat About Landed Food

    /// When a cat enters a food-eligible state (idle/thinking/toolUse), check for existing landed food.
    func notifyCatAboutLandedFood(_ cat: CatSprite) {
        guard cat.currentTargetFood == nil else { return }
        let landedFoods = activeFoods.filter { $0.state == .landed }
        guard let food = landedFoods.min(by: {
            abs($0.node.position.x - cat.containerNode.position.x)
                < abs($1.node.position.x - cat.containerNode.position.x)
        }) else { return }

        let maxDistance = CatConstants.Movement.maxFoodNoticeDistance
        let distance = abs(food.node.position.x - cat.containerNode.position.x)
        guard distance <= maxDistance else { return }
        let delay = Double(distance / maxDistance) * 0.3

#if DEBUG
        print("[FOOD] notifySingle: cat \(cat.sessionId) at x=\(cat.containerNode.position.x) walking to food at x=\(food.node.position.x) distance=\(distance)")
#endif
        cat.walkToFood(food, excitedDelay: delay) { [weak self] arrivingCat, food in
            guard let self = self else { return }
            guard food.claim(by: arrivingCat.sessionId) else {
                arrivingCat.playDisappointedReaction()
                return
            }
            arrivingCat.startEating(food) {
                food.eat { [weak self] in
                    self?.removeFood(food)
                }
            }
        }
    }

    // MARK: - Expiration

    private func checkExpirations() {
        let expiredFoods = activeFoods.filter { $0.isExpired }
        for food in expiredFoods {
            food.expire { [weak self] in
                self?.removeFood(food)
            }
        }
    }

    // MARK: - Idle Monitoring

    func updateCatIdleState(sessionId: String, isIdle: Bool) {
        if isIdle {
            if idleStartTimes[sessionId] == nil {
                idleStartTimes[sessionId] = Date()
            }
        } else {
            idleStartTimes.removeValue(forKey: sessionId)
        }
    }

    func removeCatTracking(sessionId: String) {
        idleStartTimes.removeValue(forKey: sessionId)
    }

    private func checkIdleCats() {
        guard let scene = scene else { return }
        let now = Date()
        for (sessionId, startTime) in idleStartTimes {
            let elapsed = now.timeIntervalSince(startTime)
            if elapsed >= Self.idleThresholdForFood {
                // Spawn food near this cat
                if let catX = scene.catPosition(for: sessionId) {
                    trySpawnFood(near: catX)
                }
                // Reset so we don't spam food for this cat
                idleStartTimes[sessionId] = now
            }
        }
    }

    // MARK: - Cleanup

    private func removeFood(_ food: FoodSprite) {
        activeFoods.removeAll { $0 === food }
    }
}
