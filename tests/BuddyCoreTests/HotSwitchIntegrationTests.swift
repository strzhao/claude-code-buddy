import XCTest
import Combine
@testable import BuddyCore

final class HotSwitchIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeTempStore() -> EntityModeStore {
        let url = URL(fileURLWithPath: "/tmp/hs-\(UUID().uuidString).json")
        return EntityModeStore(settingsURL: url)
    }

    func testModeChange_triggersReplaceAll() {
        let scene = MockScene()
        let manager = SessionManager(scene: scene)
        let store = makeTempStore()
        manager.bind(modeStore: store)

        let msg = HookMessage(sessionId: "s1", event: .sessionStart, tool: nil,
                              timestamp: 0, cwd: "/tmp", label: nil, pid: nil,
                              terminalId: nil, description: nil)
        manager.handle(message: msg)

        store.set(.rocket)

        let exp = expectation(description: "replaceAllCalled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if scene.replaceAllCalled { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(scene.replaceAllCalled)
        XCTAssertEqual(scene.lastReplacementMode, .rocket)
    }

    func testModeChange_preservesSessionIds() {
        let scene = MockScene()
        let manager = SessionManager(scene: scene)
        let store = makeTempStore()
        manager.bind(modeStore: store)

        for id in ["s1", "s2", "s3"] {
            manager.handle(message: HookMessage(sessionId: id, event: .sessionStart,
                                                tool: nil, timestamp: 0, cwd: "/tmp",
                                                label: nil, pid: nil, terminalId: nil,
                                                description: nil))
        }
        store.set(.rocket)

        let exp = expectation(description: "replaceAllWithAll")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if scene.lastReplacementSessionIds.count == 3 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(Set(scene.lastReplacementSessionIds), ["s1", "s2", "s3"])
    }

    func testLastEvents_cachedAndReplayedOnSwitch() {
        let scene = MockScene()
        let manager = SessionManager(scene: scene)
        let store = makeTempStore()
        manager.bind(modeStore: store)

        manager.handle(message: HookMessage(sessionId: "s1", event: .sessionStart,
                                            tool: nil, timestamp: 0, cwd: "/tmp",
                                            label: nil, pid: nil, terminalId: nil,
                                            description: nil))
        manager.handle(message: HookMessage(sessionId: "s1", event: .thinking,
                                            tool: nil, timestamp: 1, cwd: "/tmp",
                                            label: nil, pid: nil, terminalId: nil,
                                            description: nil))

        store.set(.rocket)

        let exp = expectation(description: "replayed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if scene.lastReplacementEvents["s1"] != nil { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        // Most recent event should be .thinking
        if case .thinking = scene.lastReplacementEvents["s1"] {
            // expected
        } else {
            XCTFail("Expected cached .thinking event; got \(String(describing: scene.lastReplacementEvents["s1"]))")
        }
    }
}
