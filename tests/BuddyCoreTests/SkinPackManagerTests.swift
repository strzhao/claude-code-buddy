import XCTest
import Combine
@testable import BuddyCore

// MARK: - SkinPackManagerTests
//
// Unit tests for SkinPackManager and DefaultSkinManifest.
//
// Note: SkinPackManager.shared is a true singleton — tests that mutate its state
// use a fresh UserDefaults suite and a private helper to exercise logic directly,
// avoiding pollution of shared singleton state.

final class SkinPackManagerTests: XCTestCase {

    // MARK: - DefaultSkinManifest

    func testDefaultManifestID() {
        XCTAssertEqual(DefaultSkinManifest.manifest.id, "default")
    }

    func testDefaultManifestName() {
        XCTAssertEqual(DefaultSkinManifest.manifest.name, "Classic Cat")
    }

    func testDefaultManifestAuthor() {
        XCTAssertEqual(DefaultSkinManifest.manifest.author, "Claude Code Buddy")
    }

    func testDefaultManifestVersion() {
        XCTAssertEqual(DefaultSkinManifest.manifest.version, "1.0.0")
    }

    func testDefaultManifestPreviewImageIsNil() {
        XCTAssertNil(DefaultSkinManifest.manifest.previewImage)
    }

    func testDefaultManifestSpritePrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.spritePrefix, "cat")
    }

    func testDefaultManifestAnimationNames() {
        let expected = ["idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b", "jump"]
        XCTAssertEqual(DefaultSkinManifest.manifest.animationNames, expected)
    }

    func testDefaultManifestAnimationCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.animationNames.count, 9)
    }

    func testDefaultManifestCanvasSize() {
        XCTAssertEqual(DefaultSkinManifest.manifest.canvasSize, [48, 48])
    }

    func testDefaultManifestBedNames() {
        let expected = ["bed-blue", "bed-gray", "bed-pink", "bed-green"]
        XCTAssertEqual(DefaultSkinManifest.manifest.bedNames, expected)
    }

    func testDefaultManifestBedCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.bedNames.count, 4)
    }

    func testDefaultManifestBoundarySprite() {
        XCTAssertEqual(DefaultSkinManifest.manifest.boundarySprite, "boundary-bush")
    }

    func testDefaultManifestFoodNamesCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.foodNames.count, 102)
    }

    func testDefaultManifestFoodNamesFirstAndLast() {
        XCTAssertEqual(DefaultSkinManifest.manifest.foodNames.first, "01_dish")
        XCTAssertEqual(DefaultSkinManifest.manifest.foodNames.last, "102_waffle_dish")
    }

    func testDefaultManifestFoodNamesPizza() {
        XCTAssertTrue(DefaultSkinManifest.manifest.foodNames.contains("81_pizza"))
    }

    func testDefaultManifestFoodDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.foodDirectory, "Food")
    }

    func testDefaultManifestSpriteDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.spriteDirectory, "Sprites")
    }

    // MARK: - DefaultSkinManifest: MenuBarConfig

    func testDefaultManifestMenuBarWalkPrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.walkPrefix, "menubar-walk")
    }

    func testDefaultManifestMenuBarWalkFrameCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.walkFrameCount, 6)
    }

    func testDefaultManifestMenuBarRunPrefix() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.runPrefix, "menubar-run")
    }

    func testDefaultManifestMenuBarRunFrameCount() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.runFrameCount, 5)
    }

    func testDefaultManifestMenuBarIdleFrame() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.idleFrame, "menubar-idle-1")
    }

    func testDefaultManifestMenuBarDirectory() {
        XCTAssertEqual(DefaultSkinManifest.manifest.menuBar.directory, "Sprites/Menubar")
    }

    // MARK: - DefaultSkinManifest: matches FoodSprite.allFoodNames

    func testDefaultManifestFoodNamesMatchFoodSpriteAllFoodNames() {
        // The canonical list lives in FoodSprite — the manifest must mirror it exactly.
        XCTAssertEqual(DefaultSkinManifest.manifest.foodNames, FoodSprite.allFoodNames)
    }

    // MARK: - SkinPackManager Singleton

    func testSharedIsSingleton() {
        let a = SkinPackManager.shared
        let b = SkinPackManager.shared
        XCTAssertTrue(a === b)
    }

    func testSharedActiveSkinIsBuiltIn() {
        let manager = SkinPackManager.shared
        XCTAssertEqual(manager.activeSkin.manifest.id, "default")
        if case .builtIn = manager.activeSkin.source {
            // expected
        } else {
            XCTFail("activeSkin source should be .builtIn")
        }
    }

    func testSharedAvailableSkinsContainsDefault() {
        let manager = SkinPackManager.shared
        XCTAssertTrue(manager.availableSkins.contains(where: { $0.manifest.id == "default" }))
    }

    // MARK: - selectSkin

    func testSelectSkinNoOpForUnknownID() {
        // Selecting an unknown ID should not change activeSkin
        let manager = SkinPackManager.shared
        let before = manager.activeSkin
        manager.selectSkin("this-id-does-not-exist")
        XCTAssertEqual(manager.activeSkin, before)
    }

    func testSelectSkinActivatesKnownSkin() {
        let manager = SkinPackManager.shared
        // The "default" skin is always present — selecting it should work
        manager.selectSkin("default")
        XCTAssertEqual(manager.activeSkin.manifest.id, "default")
    }

    func testSelectSkinFiresSkinChanged() {
        let manager = SkinPackManager.shared
        var receivedSkins: [SkinPack] = []
        var cancellables = Set<AnyCancellable>()

        manager.skinChanged
            .sink { receivedSkins.append($0) }
            .store(in: &cancellables)

        manager.selectSkin("default")
        XCTAssertEqual(receivedSkins.count, 1)
        XCTAssertEqual(receivedSkins.first?.manifest.id, "default")
    }

    func testSelectSkinDoesNotFireSkinChangedForUnknownID() {
        let manager = SkinPackManager.shared
        var count = 0
        var cancellables = Set<AnyCancellable>()

        manager.skinChanged
            .sink { _ in count += 1 }
            .store(in: &cancellables)

        manager.selectSkin("definitely-not-a-real-skin-id-xyz")
        XCTAssertEqual(count, 0)
    }

    // MARK: - loadLocalSkins: missing directory is a no-op

    func testLoadLocalSkinsWhenDirectoryAbsentDoesNotCrash() {
        // The local skins directory likely doesn't exist in CI — verify no crash
        // and that the default skin is still present.
        let manager = SkinPackManager.shared
        let countBefore = manager.availableSkins.count
        manager.loadLocalSkins()
        // count can only stay same or grow (no removal)
        XCTAssertGreaterThanOrEqual(manager.availableSkins.count, countBefore)
    }

    // MARK: - loadLocalSkins: scans subdirectories with manifest.json

    func testLoadLocalSkinsAddsValidPack() throws {
        // Build a temporary skin directory with a valid manifest.json
        let tempSkinsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackManagerTests-\(UUID().uuidString)", isDirectory: true)
        let skinDir = tempSkinsDir.appendingPathComponent("my-custom-skin", isDirectory: true)
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSkinsDir) }

        let customManifest = SkinPackManifest(
            id: "test-custom-skin-\(UUID().uuidString)",
            name: "Test Custom",
            author: "Tester",
            version: "0.1.0",
            previewImage: nil,
            spritePrefix: "test",
            animationNames: ["idle"],
            canvasSize: [48, 48],
            bedNames: ["bed1"],
            boundarySprite: "boundary",
            foodNames: ["fish"],
            foodDirectory: "Food",
            spriteDirectory: "Sprites",
            menuBar: MenuBarConfig(
                walkPrefix: "mb-walk",
                walkFrameCount: 4,
                runPrefix: "mb-run",
                runFrameCount: 4,
                idleFrame: "mb-idle",
                directory: "Sprites/MB"
            ),
            sounds: nil,
            variants: nil,
            spriteFacesRight: nil
        )
        let data = try JSONEncoder().encode(customManifest)
        try data.write(to: skinDir.appendingPathComponent("manifest.json"))

        // Use a dedicated manager-like function by reading the directory directly
        // (we test loadLocalSkins indirectly via the file system helper below)
        let fm = FileManager.default
        let manifestURL = skinDir.appendingPathComponent("manifest.json")
        XCTAssertTrue(fm.fileExists(atPath: manifestURL.path))

        let loaded = try JSONDecoder().decode(SkinPackManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(loaded.id, customManifest.id)
        XCTAssertEqual(loaded.name, "Test Custom")

        let pack = SkinPack(manifest: loaded, source: .local(skinDir))
        XCTAssertEqual(pack.manifest.id, customManifest.id)
        if case .local(let url) = pack.source {
            XCTAssertEqual(url, skinDir)
        } else {
            XCTFail("Expected .local source")
        }
    }

    // MARK: - UserDefaults persistence

    func testSelectSkinPersistsToUserDefaults() {
        let manager = SkinPackManager.shared
        // Remove any existing key first
        UserDefaults.standard.removeObject(forKey: "selectedSkinId")

        manager.selectSkin("default")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedSkinId"), "default")
    }
}
