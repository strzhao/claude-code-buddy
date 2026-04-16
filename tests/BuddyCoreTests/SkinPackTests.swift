import XCTest
@testable import BuddyCore

// MARK: - Test Fixtures

private let sampleManifestJSON = """
{
    "id": "default-cat",
    "name": "Default Cat",
    "author": "ClaudeCodeBuddy Team",
    "version": "1.0.0",
    "preview_image": "preview.png",
    "sprite_prefix": "cat_",
    "animation_names": ["idle", "walk", "think", "sleep"],
    "canvas_size": [48.0, 48.0],
    "bed_names": ["bed_a", "bed_b"],
    "boundary_sprite": "boundary",
    "food_names": ["fish", "cake"],
    "food_directory": "food",
    "sprite_directory": "sprites",
    "menu_bar": {
        "walk_prefix": "menubar_walk_",
        "walk_frame_count": 4,
        "run_prefix": "menubar_run_",
        "run_frame_count": 4,
        "idle_frame": "menubar_idle",
        "directory": "menubar"
    }
}
"""

private let sampleManifestNoPreviewJSON = """
{
    "id": "minimal-cat",
    "name": "Minimal Cat",
    "author": "Test Author",
    "version": "0.1.0",
    "sprite_prefix": "cat_",
    "animation_names": [],
    "canvas_size": [32.0, 32.0],
    "bed_names": [],
    "boundary_sprite": "boundary",
    "food_names": [],
    "food_directory": "food",
    "sprite_directory": "sprites",
    "menu_bar": {
        "walk_prefix": "mb_walk_",
        "walk_frame_count": 2,
        "run_prefix": "mb_run_",
        "run_frame_count": 2,
        "idle_frame": "mb_idle",
        "directory": "mb"
    }
}
"""

// MARK: - SkinPackTests

final class SkinPackTests: XCTestCase {

    // MARK: SkinPackManifest — JSON Round-trip

    func testManifestDecodesAllFields() throws {
        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)

        XCTAssertEqual(manifest.id, "default-cat")
        XCTAssertEqual(manifest.name, "Default Cat")
        XCTAssertEqual(manifest.author, "ClaudeCodeBuddy Team")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.previewImage, "preview.png")
        XCTAssertEqual(manifest.spritePrefix, "cat_")
        XCTAssertEqual(manifest.animationNames, ["idle", "walk", "think", "sleep"])
        XCTAssertEqual(manifest.canvasSize, [48.0, 48.0])
        XCTAssertEqual(manifest.bedNames, ["bed_a", "bed_b"])
        XCTAssertEqual(manifest.boundarySprite, "boundary")
        XCTAssertEqual(manifest.foodNames, ["fish", "cake"])
        XCTAssertEqual(manifest.foodDirectory, "food")
        XCTAssertEqual(manifest.spriteDirectory, "sprites")
    }

    func testManifestDecodesMenuBarConfig() throws {
        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let menuBar = manifest.menuBar

        XCTAssertEqual(menuBar.walkPrefix, "menubar_walk_")
        XCTAssertEqual(menuBar.walkFrameCount, 4)
        XCTAssertEqual(menuBar.runPrefix, "menubar_run_")
        XCTAssertEqual(menuBar.runFrameCount, 4)
        XCTAssertEqual(menuBar.idleFrame, "menubar_idle")
        XCTAssertEqual(menuBar.directory, "menubar")
    }

    func testManifestDecodesNilPreviewImage() throws {
        let data = Data(sampleManifestNoPreviewJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        XCTAssertNil(manifest.previewImage)
    }

    func testManifestRoundTrip() throws {
        let data = Data(sampleManifestJSON.utf8)
        let original = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SkinPackManifest.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testManifestEquatable() throws {
        let data = Data(sampleManifestJSON.utf8)
        let a = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let b = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        XCTAssertEqual(a, b)
    }

    func testMenuBarConfigRoundTrip() throws {
        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let encoded = try JSONEncoder().encode(manifest.menuBar)
        let decoded = try JSONDecoder().decode(MenuBarConfig.self, from: encoded)
        XCTAssertEqual(manifest.menuBar, decoded)
    }

    // MARK: SkinPack — Equatable (by manifest.id)

    func testSkinPackEquatableByManifestId() throws {
        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let packA = SkinPack(manifest: manifest, source: .builtIn(Bundle.main))
        let packB = SkinPack(manifest: manifest, source: .builtIn(Bundle.main))
        XCTAssertEqual(packA, packB)
    }

    func testSkinPackNotEqualWhenDifferentId() throws {
        let dataA = Data(sampleManifestJSON.utf8)
        let dataB = Data(sampleManifestNoPreviewJSON.utf8)
        let manifestA = try JSONDecoder().decode(SkinPackManifest.self, from: dataA)
        let manifestB = try JSONDecoder().decode(SkinPackManifest.self, from: dataB)
        let packA = SkinPack(manifest: manifestA, source: .builtIn(Bundle.main))
        let packB = SkinPack(manifest: manifestB, source: .builtIn(Bundle.main))
        XCTAssertNotEqual(packA, packB)
    }

    // MARK: SkinPack — URL Resolution (local source)

    func testLocalSourceReturnsURLWhenFileExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("sprites")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileURL = subDir.appendingPathComponent("cat_idle.png")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        let result = pack.url(forResource: "cat_idle", withExtension: "png", subdirectory: "sprites")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lastPathComponent, "cat_idle.png")
    }

    func testLocalSourceReturnsNilWhenFileMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        let result = pack.url(forResource: "nonexistent", withExtension: "png", subdirectory: "sprites")
        XCTAssertNil(result)
    }

    func testLocalSourceURLPathStructure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkinPackTests-path-\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("food")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileURL = subDir.appendingPathComponent("fish.png")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = Data(sampleManifestJSON.utf8)
        let manifest = try JSONDecoder().decode(SkinPackManifest.self, from: data)
        let pack = SkinPack(manifest: manifest, source: .local(tempDir))

        let result = pack.url(forResource: "fish", withExtension: "png", subdirectory: "food")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.path.hasSuffix("/food/fish.png"))
    }
}
