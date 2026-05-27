import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

@MainActor
final class LauncherCandidateViewSnapshotTests: XCTestCase {

    private func makeManifest(name: String, description: String) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: description,
            keywords: [],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: 5,
            requiredPath: nil
        )
    }

    // Fixture 1: 空 candidates（不应显示任何内容）
    func test_candidateView_empty_noContent() {
        let view = LauncherCandidateView(candidates: [], selectedIndex: 0)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 30)))
    }

    // Fixture 2: 1 个候选，selectedIndex = 0
    func test_candidateView_singleCandidate() {
        let candidates = [makeManifest(name: "translate", description: "Translate text between languages")]
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 0)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 30)))
    }

    // Fixture 3: 5 个候选，selectedIndex = 2（显示中间那个）
    func test_candidateView_fiveCandidates_showsSelected() {
        let candidates = [
            makeManifest(name: "translate", description: "Translate text"),
            makeManifest(name: "search", description: "Search the web"),
            makeManifest(name: "calc", description: "Calculator tool"),
            makeManifest(name: "weather", description: "Weather forecast"),
            makeManifest(name: "notes", description: "Take notes")
        ]
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 2)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 30)))
    }
}
