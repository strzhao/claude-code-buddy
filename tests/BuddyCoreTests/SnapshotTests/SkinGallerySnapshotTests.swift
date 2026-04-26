import XCTest
import AppKit
import SnapshotTesting
@testable import BuddyCore

// MARK: - SkinGallerySnapshotTests

class SkinGallerySnapshotTests: XCTestCase {

    private let gallerySize = CGSize(width: 580, height: 480)
    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    // MARK: - Tests

    func testGalleryEmpty() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        // SkinPackManager always has at least the built-in skin; this exercises
        // the default state without injecting any extra skins.
        let vc = SkinGalleryViewController()
        // Prevent live network calls during tests
        // swiftlint:disable:next force_unwrapping
        vc.catalogURL = URL(string: "file:///dev/null")!
        withOffscreenWindow(size: gallerySize) { window in
            window.contentViewController = vc
            vc.loadView()
            vc.view.layoutSubtreeIfNeeded()
            assertSnapshot(of: vc.view, as: .image(size: gallerySize))
        }
    }

    func testGalleryWithInstalledSkins() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = SkinGalleryViewController()
        // swiftlint:disable:next force_unwrapping
        vc.catalogURL = URL(string: "file:///dev/null")!
        withOffscreenWindow(size: gallerySize) { window in
            window.contentViewController = vc
            vc.loadView()
            vc.view.layoutSubtreeIfNeeded()
            assertSnapshot(of: vc.view, as: .image(size: gallerySize))
        }
    }
}
