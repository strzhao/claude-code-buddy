import XCTest
import AppKit
import SnapshotTesting
@testable import BuddyCore

// MARK: - SkinCardSnapshotTests

class SkinCardSnapshotTests: XCTestCase {

    private let cardSize = CGSize(width: 170, height: 224)
    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    // MARK: - Helpers

    private func makeCard(
        manifest: SkinPackManifest? = nil,
        isInstalled: Bool = true,
        isSelectedSkin: Bool = false,
        isDownloading: Bool = false
    ) -> SkinCardItem {
        let item = SkinCardItem()
        item.loadView()
        let m = manifest ?? SnapshotFixtures.makeManifest()
        item.configure(manifest: m, skin: nil)
        item.isInstalled = isInstalled
        item.isDownloading = isDownloading
        item.isSelectedSkin = isSelectedSkin
        return item
    }

    // MARK: - Tests

    func testCardInstalledUnselected() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let item = makeCard(isInstalled: true, isSelectedSkin: false)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }

    func testCardInstalledSelected() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let item = makeCard(isInstalled: true, isSelectedSkin: true)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }

    func testCardRemoteAvailable() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let item = makeCard(isInstalled: false, isDownloading: false)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }

    func testCardRemoteDownloading() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let item = makeCard(isInstalled: false, isDownloading: true)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }

    func testCardWithVariantsSelected() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let variants: [SkinVariant] = [
            SkinVariant(id: "blue", name: "Blue", spritePrefix: "cat-blue", previewImage: nil, bedNames: nil),
            SkinVariant(id: "red", name: "Red", spritePrefix: "cat-red", previewImage: nil, bedNames: nil),
            SkinVariant(id: "green", name: "Green", spritePrefix: "cat-green", previewImage: nil, bedNames: nil),
        ]
        let manifest = SnapshotFixtures.makeManifest(id: "multi-skin", name: "Multi Skin", variants: variants)
        let item = makeCard(manifest: manifest, isInstalled: true, isSelectedSkin: true)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }

    func testCardWithVariantsUnselected() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let variants: [SkinVariant] = [
            SkinVariant(id: "blue", name: "Blue", spritePrefix: "cat-blue", previewImage: nil, bedNames: nil),
            SkinVariant(id: "red", name: "Red", spritePrefix: "cat-red", previewImage: nil, bedNames: nil),
            SkinVariant(id: "green", name: "Green", spritePrefix: "cat-green", previewImage: nil, bedNames: nil),
        ]
        let manifest = SnapshotFixtures.makeManifest(id: "multi-skin", name: "Multi Skin", variants: variants)
        let item = makeCard(manifest: manifest, isInstalled: true, isSelectedSkin: false)
        assertSnapshot(of: item.view, as: .image(size: cardSize))
    }
}
