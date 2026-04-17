import XCTest
import Combine
@testable import BuddyCore

final class EntityModeStoreTests: XCTestCase {

    var tempDir: URL!
    var settingsPath: URL!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-mode-store-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
        settingsPath = tempDir.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        cancellables.removeAll()
        super.tearDown()
    }

    func testDefaultMode_isCat_whenNoFile() {
        let store = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(store.current, .cat)
    }

    func testSet_persistsAcrossInstances() {
        let s1 = EntityModeStore(settingsURL: settingsPath)
        s1.set(.rocket)
        let s2 = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(s2.current, .rocket)
    }

    func testSet_emitsViaPublisher() {
        let store = EntityModeStore(settingsURL: settingsPath)
        let exp = expectation(description: "publisher emits")
        var received: EntityMode?
        store.publisher
            .dropFirst()
            .sink { mode in
                received = mode
                exp.fulfill()
            }
            .store(in: &cancellables)
        store.set(.rocket)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, .rocket)
    }

    func testSet_sameMode_doesNotEmit() {
        let store = EntityModeStore(settingsURL: settingsPath)
        var emitCount = 0
        store.publisher
            .dropFirst()
            .sink { _ in emitCount += 1 }
            .store(in: &cancellables)
        store.set(.cat)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(emitCount, 0)
    }

    func testCorruptedFile_fallsBackToCat() {
        try! "garbage{not json".write(to: settingsPath, atomically: true, encoding: .utf8)
        let store = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(store.current, .cat)
    }

    func testEnvVarOverride() {
        try! """
        {"entityMode":"cat"}
        """.write(to: settingsPath, atomically: true, encoding: .utf8)
        let store = EntityModeStore(settingsURL: settingsPath,
                                     envOverride: "rocket")
        XCTAssertEqual(store.current, .rocket)
    }

    func testInvalidEnvVar_isIgnored() {
        let store = EntityModeStore(settingsURL: settingsPath,
                                     envOverride: "fish")
        XCTAssertEqual(store.current, .cat)
    }
}
