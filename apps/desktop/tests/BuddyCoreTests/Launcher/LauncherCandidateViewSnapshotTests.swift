import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

@MainActor
final class LauncherCandidateViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        // CI 字体/SF Symbol 渲染与本地不同，快照必失配；与 SkinGallerySnapshotTests 一致在 CI 跳过，本地仍跑。
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "Snapshot tests skipped on CI (font rendering differs)")
    }

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
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 44)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 44)))
    }

    // Fixture 2: 1 个候选，selectedIndex = 0
    func test_candidateView_singleCandidate() {
        let candidates = [makeManifest(name: "translate", description: "Translate text between languages")]
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 0)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 45)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 45)))
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
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 221)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 221)))
    }

    // Fixture 4 (C4 契约)：selected candidate has sage background
    func test_candidateView_selectedRow_hasSageBackground() {
        let candidates = [
            makeManifest(name: "translate", description: "Translate text between languages"),
            makeManifest(name: "search", description: "Search the web")
        ]
        // selectedIndex = 0，第一行应填充 sage 主色背景
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 0)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 89)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 89)))
    }
}
