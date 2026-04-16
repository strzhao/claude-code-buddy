import XCTest
@testable import BuddyCore

// MARK: - SkinPackAcceptanceTests
//
// Acceptance tests for SkinPackManifest and SkinPack.
//
// Written against the design specification (black-box perspective).
// These tests WILL NOT compile until the blue team merges their implementation — that is expected.
//
// Design spec coverage:
//   - SkinPackManifest: Codable + Equatable, all fields, snake_case JSON keys
//   - SkinPackManifest.MenuBarConfig: Codable correctness
//   - SkinPack: builtIn URL resolution (Assets/ prefix), local URL resolution
//   - SkinPack: local missing file returns nil
//   - SkinPack: Equatable based on manifest.id only

final class SkinPackAcceptanceTests: XCTestCase {

    // MARK: - Shared test fixtures

    /// Minimal valid JSON for SkinPackManifest with all required fields and no optional fields.
    private let minimalManifestJSON = """
    {
        "id": "default",
        "name": "Default Cat",
        "author": "Buddy Team",
        "version": "1.0.0",
        "sprite_prefix": "cat",
        "animation_names": ["idle", "thinking", "walk"],
        "canvas_size": [48.0, 48.0],
        "bed_names": ["bed1"],
        "boundary_sprite": "boundary",
        "food_names": ["fish", "kibble"],
        "food_directory": "Food",
        "sprite_directory": "Sprites",
        "menu_bar": {
            "walk_prefix": "mb_walk",
            "walk_frame_count": 4,
            "run_prefix": "mb_run",
            "run_frame_count": 6,
            "idle_frame": "mb_idle",
            "directory": "MenuBar"
        }
    }
    """

    /// Full JSON for SkinPackManifest including the optional preview_image field.
    private let fullManifestJSON = """
    {
        "id": "neon-cat",
        "name": "Neon Cat",
        "author": "Pixel Artist",
        "version": "2.3.1",
        "preview_image": "preview.png",
        "sprite_prefix": "neon",
        "animation_names": ["idle", "thinking", "walk", "run", "jump"],
        "canvas_size": [64.0, 64.0],
        "bed_names": ["bed_default", "bed_fancy"],
        "boundary_sprite": "boundary_neon",
        "food_names": ["pizza", "sushi", "ramen"],
        "food_directory": "NeonFood",
        "sprite_directory": "NeonSprites",
        "menu_bar": {
            "walk_prefix": "neon_mb_walk",
            "walk_frame_count": 8,
            "run_prefix": "neon_mb_run",
            "run_frame_count": 10,
            "idle_frame": "neon_mb_idle",
            "directory": "NeonMenuBar"
        }
    }
    """

    private var decoder: JSONDecoder { JSONDecoder() }
    private var encoder: JSONEncoder { JSONEncoder() }

    // MARK: - SkinPackManifest: Basic Decoding

    /// Verifies that all required fields decode correctly from snake_case JSON keys.
    func testManifestDecodesAllRequiredFields() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))

        XCTAssertEqual(manifest.id, "default")
        XCTAssertEqual(manifest.name, "Default Cat")
        XCTAssertEqual(manifest.author, "Buddy Team")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.spritePrefix, "cat")
        XCTAssertEqual(manifest.animationNames, ["idle", "thinking", "walk"])
        XCTAssertEqual(manifest.canvasSize, [48.0, 48.0])
        XCTAssertEqual(manifest.bedNames, ["bed1"])
        XCTAssertEqual(manifest.boundarySprite, "boundary")
        XCTAssertEqual(manifest.foodNames, ["fish", "kibble"])
        XCTAssertEqual(manifest.foodDirectory, "Food")
        XCTAssertEqual(manifest.spriteDirectory, "Sprites")
    }

    /// Verifies that the optional previewImage field is nil when absent from JSON.
    func testManifestPreviewImageIsNilWhenAbsent() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        XCTAssertNil(manifest.previewImage, "previewImage should be nil when 'preview_image' key is absent")
    }

    /// Verifies that the optional previewImage field decodes correctly when present in JSON.
    func testManifestPreviewImageDecodesWhenPresent() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(fullManifestJSON.utf8))
        XCTAssertEqual(manifest.previewImage, "preview.png",
                       "previewImage should equal 'preview.png' when 'preview_image' key is present")
    }

    /// Verifies all fields decode from the full manifest JSON including optional previewImage.
    func testManifestDecodesAllFieldsFromFullJSON() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(fullManifestJSON.utf8))

        XCTAssertEqual(manifest.id, "neon-cat")
        XCTAssertEqual(manifest.name, "Neon Cat")
        XCTAssertEqual(manifest.author, "Pixel Artist")
        XCTAssertEqual(manifest.version, "2.3.1")
        XCTAssertEqual(manifest.previewImage, "preview.png")
        XCTAssertEqual(manifest.spritePrefix, "neon")
        XCTAssertEqual(manifest.animationNames, ["idle", "thinking", "walk", "run", "jump"])
        XCTAssertEqual(manifest.canvasSize, [64.0, 64.0])
        XCTAssertEqual(manifest.bedNames, ["bed_default", "bed_fancy"])
        XCTAssertEqual(manifest.boundarySprite, "boundary_neon")
        XCTAssertEqual(manifest.foodNames, ["pizza", "sushi", "ramen"])
        XCTAssertEqual(manifest.foodDirectory, "NeonFood")
        XCTAssertEqual(manifest.spriteDirectory, "NeonSprites")
    }

    // MARK: - MenuBarConfig: Codable

    /// Verifies that MenuBarConfig decodes all fields with correct snake_case JSON keys.
    func testMenuBarConfigDecodesCorrectly() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let menuBar = manifest.menuBar

        XCTAssertEqual(menuBar.walkPrefix, "mb_walk")
        XCTAssertEqual(menuBar.walkFrameCount, 4)
        XCTAssertEqual(menuBar.runPrefix, "mb_run")
        XCTAssertEqual(menuBar.runFrameCount, 6)
        XCTAssertEqual(menuBar.idleFrame, "mb_idle")
        XCTAssertEqual(menuBar.directory, "MenuBar")
    }

    /// Verifies that MenuBarConfig with larger frame counts decodes correctly.
    func testMenuBarConfigDecodesLargeFrameCounts() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(fullManifestJSON.utf8))
        let menuBar = manifest.menuBar

        XCTAssertEqual(menuBar.walkFrameCount, 8)
        XCTAssertEqual(menuBar.runFrameCount, 10)
    }

    /// Verifies that MenuBarConfig JSON key is 'menu_bar' (snake_case).
    func testMenuBarConfigJSONKeyIsSnakeCase() throws {
        // Build JSON without the menu_bar key — should throw on decode
        let jsonWithoutMenuBar = """
        {
            "id": "test",
            "name": "Test",
            "author": "Author",
            "version": "1.0",
            "sprite_prefix": "cat",
            "animation_names": [],
            "canvas_size": [48.0, 48.0],
            "bed_names": [],
            "boundary_sprite": "b",
            "food_names": [],
            "food_directory": "Food",
            "sprite_directory": "Sprites"
        }
        """
        // menu_bar is a required field — missing it should fail decoding
        XCTAssertThrowsError(
            try decoder.decode(SkinPackManifest.self, from: Data(jsonWithoutMenuBar.utf8)),
            "Decoding should fail when required 'menu_bar' key is absent"
        )
    }

    /// Verifies camelCase key 'menuBar' is NOT accepted (must be snake_case 'menu_bar').
    func testMenuBarConfigRejectsCamelCaseKey() throws {
        let jsonWithCamelCase = """
        {
            "id": "test",
            "name": "Test",
            "author": "Author",
            "version": "1.0",
            "sprite_prefix": "cat",
            "animation_names": [],
            "canvas_size": [48.0, 48.0],
            "bed_names": [],
            "boundary_sprite": "b",
            "food_names": [],
            "food_directory": "Food",
            "sprite_directory": "Sprites",
            "menuBar": {
                "walk_prefix": "w",
                "walk_frame_count": 2,
                "run_prefix": "r",
                "run_frame_count": 3,
                "idle_frame": "i",
                "directory": "MB"
            }
        }
        """
        // camelCase 'menuBar' key should NOT satisfy the required 'menu_bar' field
        XCTAssertThrowsError(
            try decoder.decode(SkinPackManifest.self, from: Data(jsonWithCamelCase.utf8)),
            "Decoding should fail when key is 'menuBar' instead of required 'menu_bar'"
        )
    }

    // MARK: - SkinPackManifest: snake_case Key Enforcement

    /// Verifies that camelCase 'spritePrefix' key is NOT accepted (must be 'sprite_prefix').
    func testManifestRejectsNonSnakeCaseKeys() throws {
        let badJSON = """
        {
            "id": "test",
            "name": "Test",
            "author": "A",
            "version": "1.0",
            "spritePrefix": "cat",
            "animationNames": ["idle"],
            "canvasSize": [48.0, 48.0],
            "bedNames": ["bed"],
            "boundarySprite": "b",
            "foodNames": ["f"],
            "foodDirectory": "Food",
            "spriteDirectory": "Sprites",
            "menu_bar": {
                "walk_prefix": "w",
                "walk_frame_count": 2,
                "run_prefix": "r",
                "run_frame_count": 3,
                "idle_frame": "i",
                "directory": "MB"
            }
        }
        """
        // camelCase keys should NOT work — the required snake_case keys are absent
        XCTAssertThrowsError(
            try decoder.decode(SkinPackManifest.self, from: Data(badJSON.utf8)),
            "Decoding should fail when fields use camelCase instead of snake_case"
        )
    }

    // MARK: - SkinPackManifest: Encode/Decode Round-Trip

    /// Verifies that encoding and re-decoding a manifest produces an equal value.
    func testManifestEncodeDecodeRoundTrip() throws {
        let original = try decoder.decode(SkinPackManifest.self, from: Data(fullManifestJSON.utf8))
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(SkinPackManifest.self, from: encoded)

        XCTAssertEqual(original, decoded, "Round-trip encode/decode should produce an equal manifest")
    }

    /// Verifies that round-trip preserves nil previewImage.
    func testManifestRoundTripPreservesNilPreviewImage() throws {
        let original = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        XCTAssertNil(original.previewImage)

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(SkinPackManifest.self, from: encoded)

        XCTAssertNil(decoded.previewImage, "nil previewImage should survive encode/decode round-trip")
        XCTAssertEqual(original, decoded)
    }

    // MARK: - SkinPackManifest: Equatable

    /// Two manifests decoded from identical JSON should be equal.
    func testManifestEquatableIdenticalJSONProducesEqualValues() throws {
        let a = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let b = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        XCTAssertEqual(a, b, "Two manifests decoded from identical JSON should be equal")
    }

    /// Two manifests with different ids should not be equal.
    func testManifestEquatableDifferentIDsNotEqual() throws {
        let jsonA = minimalManifestJSON // id: "default"
        let jsonB = fullManifestJSON    // id: "neon-cat"

        let a = try decoder.decode(SkinPackManifest.self, from: Data(jsonA.utf8))
        let b = try decoder.decode(SkinPackManifest.self, from: Data(jsonB.utf8))
        XCTAssertNotEqual(a, b, "Manifests with different ids should not be equal")
    }

    /// Two manifests with same id but different fields should be compared by value (all fields).
    func testManifestEquatableSameIDDifferentFieldsNotEqual() throws {
        let jsonA = minimalManifestJSON // id: "default", name: "Default Cat"
        let jsonB = """
        {
            "id": "default",
            "name": "Modified Cat",
            "author": "Other Author",
            "version": "9.9.9",
            "sprite_prefix": "modified",
            "animation_names": ["walk"],
            "canvas_size": [32.0, 32.0],
            "bed_names": ["bed2"],
            "boundary_sprite": "wall",
            "food_names": ["apple"],
            "food_directory": "ModFood",
            "sprite_directory": "ModSprites",
            "menu_bar": {
                "walk_prefix": "x_walk",
                "walk_frame_count": 2,
                "run_prefix": "x_run",
                "run_frame_count": 2,
                "idle_frame": "x_idle",
                "directory": "XMB"
            }
        }
        """
        let a = try decoder.decode(SkinPackManifest.self, from: Data(jsonA.utf8))
        let b = try decoder.decode(SkinPackManifest.self, from: Data(jsonB.utf8))
        XCTAssertNotEqual(a, b, "Manifests with same id but different fields should not be equal")
    }

    // MARK: - SkinPack: Equatable Based on manifest.id

    /// Two SkinPack values with same manifest.id but different sources should be equal.
    func testSkinPackEquatableBasedOnManifestID() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))

        let packA = SkinPack(manifest: manifest, source: .builtIn(Bundle.main))
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let packB = SkinPack(manifest: manifest, source: .local(tempURL))

        XCTAssertEqual(packA, packB,
                       "SkinPack values with the same manifest.id should be equal regardless of source")
    }

    /// Two SkinPack values with different manifest.ids should not be equal.
    func testSkinPackNotEqualWhenDifferentManifestID() throws {
        let manifestA = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let manifestB = try decoder.decode(SkinPackManifest.self, from: Data(fullManifestJSON.utf8))

        let packA = SkinPack(manifest: manifestA, source: .builtIn(Bundle.main))
        let packB = SkinPack(manifest: manifestB, source: .builtIn(Bundle.main))

        XCTAssertNotEqual(packA, packB,
                          "SkinPack values with different manifest.ids should not be equal")
    }

    // MARK: - SkinPack: local URL Resolution

    /// SkinPack.local resolves an existing file by concatenating baseURL + subdirectory + name.ext.
    func testSkinPackLocalResolvesExistingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create subdirectory + file
        let subDir = tempDir.appendingPathComponent("Sprites", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileURL = subDir.appendingPathComponent("cat_idle.png")
        try Data().write(to: fileURL)

        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        let resolved = pack.url(forResource: "cat_idle", withExtension: "png", subdirectory: "Sprites")
        XCTAssertNotNil(resolved, "local SkinPack should resolve an existing file")
        XCTAssertEqual(resolved?.lastPathComponent, "cat_idle.png")
    }

    /// SkinPack.local returns nil when the file does not exist on disk.
    func testSkinPackLocalReturnsNilForMissingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        let resolved = pack.url(forResource: "nonexistent", withExtension: "png", subdirectory: "Sprites")
        XCTAssertNil(resolved, "local SkinPack should return nil for a file that does not exist")
    }

    /// SkinPack.local uses FileManager.fileExists to validate presence — a non-file path returns nil.
    func testSkinPackLocalReturnsNilForNonExistentSubdirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        // The subdirectory "GhostDir" does not exist
        let resolved = pack.url(forResource: "sprite", withExtension: "png", subdirectory: "GhostDir")
        XCTAssertNil(resolved, "local SkinPack should return nil when subdirectory does not exist")
    }

    // MARK: - SkinPack: builtIn URL Resolution (Assets/ prefix)

    /// SkinPack.builtIn passes subdirectory with "Assets/" prepended to bundle.url().
    /// We use a real bundle (BuddyCore) which has an Assets folder in its resources.
    func testSkinPackBuiltInPrependsAssetsPrefixToSubdirectory() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))

        // Use the BuddyCore bundle (the module under test)
        let bundle = Bundle(for: SkinPackAcceptanceTestsBundleMarker.self)
        let pack = SkinPack(manifest: manifest, source: .builtIn(bundle))

        // We cannot guarantee a specific file exists in the test bundle,
        // but we CAN verify the call doesn't crash and follows the contract:
        // if the resource doesn't exist in Assets/Sprites, nil is returned (not a crash).
        let resolved = pack.url(forResource: "nonexistent_sprite", withExtension: "png", subdirectory: "Sprites")
        // Should be nil — no such file — but must NOT throw or crash
        XCTAssertNil(resolved,
                     "builtIn SkinPack should return nil (not crash) for a nonexistent resource")
    }

    /// Verifies that builtIn prepends "Assets/" by checking that a direct bundle lookup
    /// without the prefix would behave differently (sanity-check of the contract).
    func testSkinPackBuiltInSubdirectoryPrefixContract() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))

        // Create a mock bundle subclass to capture the subdirectory argument
        let capturingBundle = CapturingBundle()
        let pack = SkinPack(manifest: manifest, source: .builtIn(capturingBundle))

        _ = pack.url(forResource: "cat_idle", withExtension: "png", subdirectory: "Sprites")

        XCTAssertEqual(capturingBundle.lastSubdirectory, "Assets/Sprites",
                       "builtIn should prepend 'Assets/' to the subdirectory argument passed to bundle.url()")
    }

    // MARK: - SkinPack: SkinSource Struct Integrity

    /// SkinPack.source is .builtIn for a bundle-backed pack.
    func testSkinPackSourceIsBuiltIn() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let pack = SkinPack(manifest: manifest, source: .builtIn(Bundle.main))

        if case .builtIn = pack.source {
            // pass
        } else {
            XCTFail("SkinPack source should be .builtIn")
        }
    }

    /// SkinPack.source is .local for a file-URL-backed pack.
    func testSkinPackSourceIsLocal() throws {
        let manifest = try decoder.decode(SkinPackManifest.self, from: Data(minimalManifestJSON.utf8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let pack = SkinPack(manifest: manifest, source: .local(url))

        if case .local = pack.source {
            // pass
        } else {
            XCTFail("SkinPack source should be .local")
        }
    }
}

// MARK: - CapturingBundle

/// A Bundle subclass that records the last subdirectory argument passed to url(forResource:withExtension:subdirectory:).
private final class CapturingBundle: Bundle {
    private(set) var lastSubdirectory: String?

    override func url(forResource name: String?, withExtension ext: String?, subdirectory subpath: String?) -> URL? {
        lastSubdirectory = subpath
        return nil
    }
}

// MARK: - Bundle marker for test target

/// Marker class used to locate the BuddyCoreTests bundle at runtime.
private final class SkinPackAcceptanceTestsBundleMarker {}
