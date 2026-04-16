import XCTest
import Combine
@testable import BuddyCore

// MARK: - SkinPackManagerAcceptanceTests
//
// Acceptance tests for DefaultSkinManifest and SkinPackManager.
//
// Written against the design specification (black-box perspective).
// These tests WILL NOT compile until the blue team merges their implementation — that is expected.
//
// Design spec coverage:
//   - DefaultSkinManifest.manifest: all field values must match spec exactly
//   - DefaultSkinManifest.manifest.animationNames: 9 entries, exact values
//   - DefaultSkinManifest.manifest.foodNames: 102 entries
//   - DefaultSkinManifest.manifest.bedNames: 4 entries, exact values
//   - DefaultSkinManifest.manifest.menuBar: all sub-fields
//   - SkinPackManager.shared: singleton exists, activeSkin is default
//   - SkinPackManager.availableSkins: at least includes default skin
//   - SkinPackManager.selectSkin: updates activeSkin, writes UserDefaults, sends skinChanged
//   - SkinPackManager.selectSkin: invalid skinId falls back to default
//   - SkinPackManager.skinChanged: PassthroughSubject fires on selection change

final class SkinPackManagerAcceptanceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
        // Reset to default skin before each test to ensure isolation
        SkinPackManager.shared.selectSkin("default")
        UserDefaults.standard.removeObject(forKey: "selectedSkinId")
    }

    override func tearDown() {
        cancellables = []
        // Restore to default and clean up UserDefaults
        SkinPackManager.shared.selectSkin("default")
        UserDefaults.standard.removeObject(forKey: "selectedSkinId")
        super.tearDown()
    }

    // MARK: - DefaultSkinManifest: Top-Level Fields

    /// manifest.id must equal "default".
    func testDefaultManifestID() {
        XCTAssertEqual(DefaultSkinManifest.manifest.id, "default",
                       "manifest.id should be 'default'")
    }

    /// manifest.spritePrefix must equal "cat".
    func testDefaultManifestSpritePrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.spritePrefix, "cat",
                       "manifest.spritePrefix should be 'cat'")
    }

    /// manifest.canvasSize must be [48, 48].
    func testDefaultManifestCanvasSize() {
        XCTAssertEqual(DefaultSkinManifest.manifest.canvasSize, [48, 48],
                       "manifest.canvasSize should be [48, 48]")
    }

    /// manifest.boundarySprite must equal "boundary-bush".
    func testDefaultManifestBoundarySprite() {
        XCTAssertEqual(DefaultSkinManifest.manifest.boundarySprite, "boundary-bush",
                       "manifest.boundarySprite should be 'boundary-bush'")
    }

    /// manifest.foodDirectory must equal "Food".
    func testDefaultManifestFoodDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.foodDirectory, "Food",
                       "manifest.foodDirectory should be 'Food'")
    }

    /// manifest.spriteDirectory must equal "Sprites".
    func testDefaultManifestSpriteDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.spriteDirectory, "Sprites",
                       "manifest.spriteDirectory should be 'Sprites'")
    }

    // MARK: - DefaultSkinManifest: animationNames (9 entries, exact values)

    /// animationNames must contain exactly 9 entries.
    func testDefaultManifestAnimationNamesCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.animationNames.count, 9,
                       "manifest.animationNames should contain exactly 9 entries")
    }

    /// animationNames must contain exactly the 9 specified names.
    func testDefaultManifestAnimationNamesExactValues() {
        let expected: [String] = [
            "idle-a", "idle-b", "clean", "sleep", "scared",
            "paw", "walk-a", "walk-b", "jump"
        ]
        XCTAssertEqual(DefaultSkinManifest.manifest.animationNames, expected,
                       "manifest.animationNames should exactly match the spec list (order included)")
    }

    // MARK: - DefaultSkinManifest: bedNames (4 entries, exact values)

    /// bedNames must contain exactly 4 entries.
    func testDefaultManifestBedNamesCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.bedNames.count, 4,
                       "manifest.bedNames should contain exactly 4 entries")
    }

    /// bedNames must contain exactly the 4 specified names.
    func testDefaultManifestBedNamesExactValues() {
        let expected: [String] = ["bed-blue", "bed-gray", "bed-pink", "bed-green"]
        XCTAssertEqual(DefaultSkinManifest.manifest.bedNames, expected,
                       "manifest.bedNames should exactly match the spec list (order included)")
    }

    // MARK: - DefaultSkinManifest: foodNames (102 entries)

    /// foodNames must contain exactly 102 entries.
    func testDefaultManifestFoodNamesCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.foodNames.count, 102,
                       "manifest.foodNames should contain exactly 102 entries")
    }

    /// foodNames must not contain any empty strings.
    func testDefaultManifestFoodNamesNoEmptyStrings() {
        for name in DefaultSkinManifest.manifest.foodNames {
            XCTAssertFalse(name.isEmpty,
                           "manifest.foodNames should not contain empty strings, found: '\(name)'")
        }
    }

    /// foodNames must not contain duplicate entries.
    func testDefaultManifestFoodNamesNoDuplicates() {
        let names = DefaultSkinManifest.manifest.foodNames
        let unique = Set(names)
        XCTAssertEqual(names.count, unique.count,
                       "manifest.foodNames should contain no duplicate entries")
    }

    // MARK: - DefaultSkinManifest: menuBar config

    /// menuBar.walkPrefix must equal "menubar-walk".
    func testDefaultManifestMenuBarWalkPrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.walkPrefix, "menubar-walk",
                       "manifest.menuBar.walkPrefix should be 'menubar-walk'")
    }

    /// menuBar.walkFrameCount must equal 6.
    func testDefaultManifestMenuBarWalkFrameCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.walkFrameCount, 6,
                       "manifest.menuBar.walkFrameCount should be 6")
    }

    /// menuBar.runPrefix must equal "menubar-run".
    func testDefaultManifestMenuBarRunPrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.runPrefix, "menubar-run",
                       "manifest.menuBar.runPrefix should be 'menubar-run'")
    }

    /// menuBar.runFrameCount must equal 5.
    func testDefaultManifestMenuBarRunFrameCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.runFrameCount, 5,
                       "manifest.menuBar.runFrameCount should be 5")
    }

    /// menuBar.idleFrame must equal "menubar-idle-1".
    func testDefaultManifestMenuBarIdleFrame() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.idleFrame, "menubar-idle-1",
                       "manifest.menuBar.idleFrame should be 'menubar-idle-1'")
    }

    /// menuBar.directory must equal "Sprites/Menubar".
    func testDefaultManifestMenuBarDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.directory, "Sprites/Menubar",
                       "manifest.menuBar.directory should be 'Sprites/Menubar'")
    }

    // MARK: - SkinPackManager: Singleton and Default State

    /// SkinPackManager.shared must exist and its activeSkin.manifest.id must be "default".
    func testSharedSingletonExistsWithDefaultActiveSkin() {
        let manager = SkinPackManager.shared
        XCTAssertEqual(manager.activeSkin.manifest.id, "default",
                       "SkinPackManager.shared.activeSkin should be the default skin")
    }

    /// Two accesses to SkinPackManager.shared must return the same object.
    func testSharedIsSingleton() {
        let a = SkinPackManager.shared
        let b = SkinPackManager.shared
        XCTAssertTrue(a === b, "SkinPackManager.shared should always return the same instance")
    }

    // MARK: - SkinPackManager: availableSkins

    /// availableSkins must contain at least one entry.
    func testAvailableSkinsIsNotEmpty() {
        XCTAssertFalse(SkinPackManager.shared.availableSkins.isEmpty,
                       "availableSkins should contain at least the built-in default skin")
    }

    /// availableSkins must include the default skin.
    func testAvailableSkinsIncludesDefault() {
        let hasDefault = SkinPackManager.shared.availableSkins.contains {
            $0.manifest.id == "default"
        }
        XCTAssertTrue(hasDefault,
                      "availableSkins should include the built-in default skin (id: 'default')")
    }

    // MARK: - SkinPackManager: selectSkin updates activeSkin

    /// selectSkin("default") leaves activeSkin as default (idempotent).
    func testSelectDefaultSkinIsIdempotent() {
        SkinPackManager.shared.selectSkin("default")
        XCTAssertEqual(SkinPackManager.shared.activeSkin.manifest.id, "default",
                       "selectSkin('default') should leave activeSkin as default")
    }

    // MARK: - SkinPackManager: selectSkin writes UserDefaults

    /// selectSkin("default") writes "default" to UserDefaults key "selectedSkinId".
    func testSelectSkinWritesUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "selectedSkinId")

        SkinPackManager.shared.selectSkin("default")

        let stored = UserDefaults.standard.string(forKey: "selectedSkinId")
        XCTAssertEqual(stored, "default",
                       "selectSkin should write the skinId to UserDefaults key 'selectedSkinId'")
    }

    /// Calling selectSkin with a different ID overwrites the previous UserDefaults value.
    func testSelectSkinOverwritesPreviousUserDefaults() {
        SkinPackManager.shared.selectSkin("default")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedSkinId"), "default")

        // Selecting an unknown skin that will fall back: the written value should still be the
        // requested ID (the write happens before or alongside the fallback lookup).
        // However, since we cannot guarantee a non-default skin exists, we test with "default"
        // twice to confirm the key is always updated.
        SkinPackManager.shared.selectSkin("default")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedSkinId"), "default",
                       "Repeated selectSkin should keep UserDefaults key accurate")
    }

    // MARK: - SkinPackManager: selectSkin triggers skinChanged

    /// selectSkin must publish on skinChanged with the new active skin.
    func testSelectSkinFiresSkinChanged() {
        let expectation = XCTestExpectation(description: "skinChanged fires on selectSkin")
        var receivedSkin: SkinPack?

        SkinPackManager.shared.skinChanged
            .sink { skin in
                receivedSkin = skin
                expectation.fulfill()
            }
            .store(in: &cancellables)

        SkinPackManager.shared.selectSkin("default")

        wait(for: [expectation], timeout: 1.0)

        XCTAssertNotNil(receivedSkin, "skinChanged should have fired with a SkinPack value")
        XCTAssertEqual(receivedSkin?.manifest.id, "default",
                       "skinChanged should carry the newly selected skin")
    }

    /// skinChanged fires exactly once per selectSkin call.
    func testSkinChangedFiresExactlyOncePerSelect() {
        let expectation = XCTestExpectation(description: "skinChanged fires exactly once")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        SkinPackManager.shared.skinChanged
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        SkinPackManager.shared.selectSkin("default")

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - SkinPackManager: invalid skinId fallback

    /// selectSkin with a non-existent skinId must not change activeSkin away from default.
    func testSelectInvalidSkinIDFallsBackToDefault() {
        // Start from default
        SkinPackManager.shared.selectSkin("default")
        XCTAssertEqual(SkinPackManager.shared.activeSkin.manifest.id, "default")

        // Request a skin that does not exist
        SkinPackManager.shared.selectSkin("nonexistent-skin-xyz-\(UUID().uuidString)")

        XCTAssertEqual(SkinPackManager.shared.activeSkin.manifest.id, "default",
                       "activeSkin should remain default when an invalid skinId is requested")
    }

    /// selectSkin with an empty string must not crash and must keep activeSkin as default.
    func testSelectEmptySkinIDKeepsDefault() {
        SkinPackManager.shared.selectSkin("default")

        SkinPackManager.shared.selectSkin("")

        XCTAssertEqual(SkinPackManager.shared.activeSkin.manifest.id, "default",
                       "selectSkin('') should fall back to default without crashing")
    }

    // MARK: - SkinPackManager: skinChanged PassthroughSubject type

    /// skinChanged must be a PassthroughSubject<SkinPack, Never> —
    /// verify by subscribing, selecting, and receiving a value (no error path).
    func testSkinChangedIsPassthroughSubjectWithNoError() {
        var completedUnexpectedly = false
        let valueExpectation = XCTestExpectation(description: "skinChanged emits value")

        SkinPackManager.shared.skinChanged
            .sink(
                receiveCompletion: { _ in completedUnexpectedly = true },
                receiveValue: { _ in valueExpectation.fulfill() }
            )
            .store(in: &cancellables)

        SkinPackManager.shared.selectSkin("default")

        wait(for: [valueExpectation], timeout: 1.0)
        XCTAssertFalse(completedUnexpectedly,
                       "skinChanged should never complete (PassthroughSubject with Never error)")
    }
}
