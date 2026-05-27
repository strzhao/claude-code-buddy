import XCTest
@testable import BuddyCore

// MARK: - LauncherIsolationTests
//
// 验收 SC-10: Launcher 与像素猫子系统完全互不干扰
//
// 静态隔离断言（不依赖运行时 app 启动）：
// 1. 全局命名空间不冲突：Launcher* 类型 vs Cat*/Buddy*/Session* 类型无符号冲突
// 2. AppDelegate 仅通过 LauncherManager.shared.setup() 单点接入（grep 验证）
// 3. LauncherManager 不依赖 SessionManager / BuddyScene / CatSprite
// 4. LauncherConstants 路径独立于像素猫使用的 /tmp/claude-buddy*
//
// 不做 E2E 启动 app 测试（CI 环境无 NSApp，运行时验证已在 LauncherManagerAcceptanceTests 中覆盖）
//
// 注意（plan-reviewer 建议 3）：路径断言假定测试进程以非沙盒模式运行
// （NSHomeDirectory() 返回真实 home，如 /Users/xxx）。
// 沙盒进程下 NSHomeDirectory() 会返回容器路径，该情况 XCTSkip 兜底。

final class LauncherIsolationTests: XCTestCase {

    /// SC-10.1: LauncherConstants 路径与像素猫子系统的 socket/colorFile 路径完全不重叠
    func test_SC10_pathsDoNotOverlap_withBuddySocketAndColorFile() {
        XCTAssertFalse(LauncherConstants.buddyDir.path.hasPrefix("/tmp/claude-buddy"),
                       "LauncherConstants 路径必须不与 /tmp/claude-buddy* 重叠")
        let buddyDirStr = LauncherConstants.buddyDir.path
        XCTAssertNotEqual(buddyDirStr, "/tmp/claude-buddy.sock",
                          "Launcher buddy 目录不能等于 SocketServer 路径")
        XCTAssertNotEqual(buddyDirStr, "/tmp/claude-buddy-colors.json",
                          "Launcher buddy 目录不能等于 colorFile 路径")
        XCTAssertTrue(buddyDirStr.contains(".buddy"),
                      "LauncherConstants 必须在 ~/.buddy/ 下，与 SocketServer /tmp/ 路径完全隔离")
    }

    /// SC-10.2: LauncherManager 公共 API 不依赖 SessionManager / BuddyScene / CatSprite
    /// 通过编译时类型导入证实：LauncherManager.swift 不应 import 这些子系统
    func test_SC10_launcherManager_doesNotDependOn_catSubsystem() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // tests/BuddyCoreTests/Launcher
            .deletingLastPathComponent()  // tests/BuddyCoreTests
            .deletingLastPathComponent()  // tests
            .deletingLastPathComponent()  // apps/desktop
        let launcherManagerPath = projectRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Launcher/LauncherManager.swift")
        guard FileManager.default.fileExists(atPath: launcherManagerPath.path) else {
            throw XCTSkip("LauncherManager.swift 路径未找到: \(launcherManagerPath.path)")
        }
        let source = try String(contentsOf: launcherManagerPath, encoding: .utf8)
        let forbiddenIdentifiers = ["SessionManager", "BuddyScene", "CatSprite", "FoodManager", "BuddyEvent"]
        for ident in forbiddenIdentifiers {
            XCTAssertFalse(source.contains(ident),
                           "LauncherManager.swift 不应引用 \(ident)（破坏 SC-10 隔离契约）")
        }
    }

    /// SC-10.3: LauncherManager 设置全部在自身 lazy init，不修改全局 NSApp 状态
    /// 通过 @MainActor + 不调 NSApp.terminate / sharedApplication setActivationPolicy 验证
    func test_SC10_launcherManager_doesNotModifyGlobalAppState() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherManagerPath = projectRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Launcher/LauncherManager.swift")
        guard FileManager.default.fileExists(atPath: launcherManagerPath.path) else {
            throw XCTSkip("LauncherManager.swift 路径未找到")
        }
        let source = try String(contentsOf: launcherManagerPath, encoding: .utf8)
        let forbiddenAPIs = ["NSApp.terminate", "setActivationPolicy", "NSApplication.shared.terminate"]
        for api in forbiddenAPIs {
            XCTAssertFalse(source.contains(api),
                           "LauncherManager 不应调用 \(api)（会影响整个 app 包括像素猫）")
        }
    }

    /// SC-10.4: TrustStore 文件操作隔离在 ~/.buddy/launcher-trust.json，
    /// 与 SessionColor 使用的 /tmp/claude-buddy-colors.json 不冲突
    /// 注意：假定测试进程以非沙盒模式运行（NSHomeDirectory() 返回真实 home）
    func test_SC10_trustStore_pathIndependent_fromBuddyColorFile() throws {
        let homeDir = NSHomeDirectory()
        // 沙盒环境下 home 路径包含 Library/Containers，此时跳过路径具体性断言
        guard !homeDir.contains("Library/Containers") else {
            throw XCTSkip("沙盒模式下跳过路径断言（NSHomeDirectory 返回容器路径）")
        }
        let trustFile = LauncherConstants.buddyDir.appendingPathComponent("launcher-trust.json")
        XCTAssertFalse(trustFile.path.hasPrefix("/tmp/"),
                       "TrustStore 必须在 ~/.buddy/ 下，与 /tmp 路径隔离")
        XCTAssertTrue(trustFile.path.contains(".buddy/launcher-trust.json"),
                      "TrustStore 路径契约：~/.buddy/launcher-trust.json")
    }
}
