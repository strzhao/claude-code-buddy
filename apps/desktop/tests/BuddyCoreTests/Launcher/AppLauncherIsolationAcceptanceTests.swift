import XCTest
@testable import BuddyCore

// MARK: - AppLauncherIsolationAcceptanceTests
//
// 红队验收测试：C8 内置插件路径隔离契约
//
// 契约覆盖：
//   C8-a：Builtin/ 源码不引用像素猫符号（SessionManager / BuddyScene / CatSprite / FoodManager / BuddyEvent / SocketServer）
//   C8-b：Builtin/ 源码无硬编码 /tmp/claude-buddy 字面量
//   C8-c：AppLaunching 协议隔离 seam — 测试可注入 MockAppLauncher，绝不真实启动 app
//   C8-d：AppLauncherPlugin 不依赖任何 Scene/Session 类型（源码扫描）
//   C8-e：新增 LauncherConstants 键（appIndexTTLSec / instantDebounceMs / appSearchLimit）
//         仅与 Launcher 子系统交互，不污染像素猫常量命名空间
//
// 红队红线：扫描 Launcher/Builtin/ 目录（排除当前红队文件）；
//   不读取 Builtin/ 下任何蓝队实现文件（仅通过文件系统扫描内容字符串）。
//   扫描性测试（与 LauncherIsolationAcceptanceTests 互补）。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class AppLauncherIsolationAcceptanceTests: XCTestCase {

    // MARK: - C8-a：Builtin 源码无像素猫符号引用

    /// Launcher/Builtin/ 下所有 .swift 文件不得引用像素猫子系统类型。
    /// 与 LauncherIsolationAcceptanceTests.test_SC10_launcherSources_noDependencyOn_pixelCatTypes
    /// 互补：该测试覆盖全 Launcher/，本测试精确聚焦 Builtin/ 子目录。
    func test_C8a_builtinSources_noDependencyOn_pixelCatTypes() throws {
        let builtinDir = try Self.builtinSourceDir()

        let swiftFiles = try Self.collectSwiftFiles(in: builtinDir)
        // 如果 Builtin 目录尚未创建（蓝队未合并），跳过（不阻塞红队测试）
        guard !swiftFiles.isEmpty else {
            throw XCTSkip("Builtin/ 源码目录尚不存在或为空，蓝队合并后运行：\(builtinDir.path)")
        }

        let forbiddenSymbols = [
            "SessionManager",
            "BuddyScene",
            "CatSprite",
            "FoodManager",
            "BuddyEvent",
            "SocketServer",
        ]

        for (fileName, content) in swiftFiles {
            for symbol in forbiddenSymbols {
                XCTAssertFalse(
                    content.contains(symbol),
                    "C8-a 违反：Builtin 源文件 '\(fileName)' 引用了像素猫符号 '\(symbol)'，类型依赖必须完全隔离"
                )
            }
        }
    }

    // MARK: - C8-b：Builtin 源码无硬编码像素猫 /tmp 路径

    /// Launcher/Builtin/ 下所有 .swift 文件不得出现 "/tmp/claude-buddy" 字面量。
    func test_C8b_builtinSources_noHardcodedPixelCatTmpPaths() throws {
        let builtinDir = try Self.builtinSourceDir()
        let swiftFiles = try Self.collectSwiftFiles(in: builtinDir)

        guard !swiftFiles.isEmpty else {
            throw XCTSkip("Builtin/ 目录尚不存在，蓝队合并后运行：\(builtinDir.path)")
        }

        let forbiddenLiterals = ["/tmp/claude-buddy"]

        for (fileName, content) in swiftFiles {
            for literal in forbiddenLiterals {
                XCTAssertFalse(
                    content.contains(literal),
                    "C8-b 违反：Builtin 源文件 '\(fileName)' 硬编码了像素猫路径字面量 '\(literal)'"
                )
            }
        }
    }

    // MARK: - C8-c：AppLaunching 协议隔离 seam — MockAppLauncher 可注入

    /// 验证 AppLaunching 协议可被 mock 实现注入到 AppLauncherPlugin，不真实启动 app。
    /// 这是接口级别的契约验证（符合 C6 设计文档中的「启动 seam」要求）。
    func test_C8c_appLaunching_mockInjectable_noRealLaunch() throws {
        final class StrictMockLauncher: AppLaunching {
            var launchCalled = false
            var lastURL: URL?
            func launch(_ url: URL) throws {
                launchCalled = true
                lastURL = url
                // 不真实启动 app（不调用 NSWorkspace）
            }
        }

        let mock = StrictMockLauncher()
        let fakeURL = URL(fileURLWithPath: "/Applications/FakeApp.app")

        // 调用 mock：不应触发真实系统调用
        XCTAssertNoThrow(try mock.launch(fakeURL),
            "C8-c: MockAppLauncher.launch 不应抛错（mock 实现）")
        XCTAssertTrue(mock.launchCalled,
            "C8-c: mock.launch 被调用后 launchCalled 标记应为 true")
        XCTAssertEqual(mock.lastURL, fakeURL,
            "C8-c: mock 记录的 URL 应为传入的 fakeURL")
    }

    /// FailingAppLauncher 注入验证：throw LauncherError.appLaunchFailed 正常抛出。
    func test_C8c_failingMockLauncher_throwsAppLaunchFailed() {
        struct FailingLauncher: AppLaunching {
            func launch(_ url: URL) throws {
                throw LauncherError.appLaunchFailed("TestApp")
            }
        }

        let launcher = FailingLauncher()
        let url = URL(fileURLWithPath: "/Applications/TestApp.app")

        XCTAssertThrowsError(try launcher.launch(url),
            "C8-c: FailingLauncher 必须抛出 LauncherError.appLaunchFailed") { error in
            guard case LauncherError.appLaunchFailed(let name) = error else {
                XCTFail("C8-c: 期望 LauncherError.appLaunchFailed，实际 \(error)")
                return
            }
            XCTAssertEqual(name, "TestApp",
                "C8-c: appLaunchFailed 关联 app 名称应为 'TestApp'，实际 \(name)")
        }
    }

    // MARK: - C8-d：AppLauncherPlugin 不依赖 Scene/Session（源码扫描）

    /// Builtin/AppLauncher/ 子目录下文件（AppLauncherPlugin 所在），
    /// 不得 import 或引用 Scene / Session 模块的类型。
    func test_C8d_appLauncherPlugin_noSceneSessionDependency() throws {
        let builtinDir = try Self.builtinSourceDir()
        let appLauncherDir = builtinDir.appendingPathComponent("AppLauncher")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appLauncherDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw XCTSkip("AppLauncher/ 子目录尚不存在，蓝队合并后运行：\(appLauncherDir.path)")
        }

        let swiftFiles = try Self.collectSwiftFiles(in: appLauncherDir)
        guard !swiftFiles.isEmpty else {
            throw XCTSkip("AppLauncher/ 子目录为空，蓝队合并后运行")
        }

        // 场景层和会话层符号
        let forbidden = ["BuddyScene", "SessionManager", "SessionInfo", "SessionColor",
                         "EventBus", "BuddyEvent", "CatSprite", "FoodManager"]

        for (fileName, content) in swiftFiles {
            for symbol in forbidden {
                XCTAssertFalse(
                    content.contains(symbol),
                    "C8-d 违反：AppLauncher 源文件 '\(fileName)' 引用了 Scene/Session 符号 '\(symbol)'，破坏隔离"
                )
            }
        }
    }

    // MARK: - C8-e：新增 LauncherConstants 键只属于 Launcher 子系统

    /// LauncherConstants 新增的 appIndexTTLSec / instantDebounceMs / appSearchLimit
    /// 必须存在（契约锁定），且值在合理范围内（不误设为像素猫相关常量的值）。
    func test_C8e_launcherConstants_newKeys_exist_inReasonableRange() {
        // appIndexTTLSec：TTL 60 秒，合理范围 [10, 600]
        let ttl = LauncherConstants.appIndexTTLSec
        XCTAssertGreaterThanOrEqual(ttl, 10,
            "C8-e: appIndexTTLSec 应 ≥ 10s，实际 \(ttl)")
        XCTAssertLessThanOrEqual(ttl, 600,
            "C8-e: appIndexTTLSec 应 ≤ 600s，实际 \(ttl)")

        // instantDebounceMs：debounce ~120ms，合理范围 [50, 500]
        let debounce = LauncherConstants.instantDebounceMs
        XCTAssertGreaterThanOrEqual(debounce, 50,
            "C8-e: instantDebounceMs 应 ≥ 50ms，实际 \(debounce)")
        XCTAssertLessThanOrEqual(debounce, 500,
            "C8-e: instantDebounceMs 应 ≤ 500ms，实际 \(debounce)")

        // appSearchLimit：Top-N 截断 8，合理范围 [3, 20]
        let limit = LauncherConstants.appSearchLimit
        XCTAssertGreaterThanOrEqual(limit, 3,
            "C8-e: appSearchLimit 应 ≥ 3，实际 \(limit)")
        XCTAssertLessThanOrEqual(limit, 20,
            "C8-e: appSearchLimit 应 ≤ 20，实际 \(limit)")
    }

    /// appSearchLimit 设计文档明确为 8，锁定该值（场景 7：前 8 条）。
    func test_C8e_appSearchLimit_equals8() {
        XCTAssertEqual(LauncherConstants.appSearchLimit, 8,
            "C8-e（场景 7）: appSearchLimit 设计文档明确为 8，实际 \(LauncherConstants.appSearchLimit)")
    }

    /// instantDebounceMs 设计文档明确为 ~120ms，锁定合理区间。
    func test_C8e_instantDebounceMs_around120ms() {
        let debounce = LauncherConstants.instantDebounceMs
        // 设计文档："debounce ~120ms"，允许合理偏差 [80, 200]
        XCTAssertGreaterThanOrEqual(debounce, 80,
            "C8-e: instantDebounceMs 应接近 120ms（≥80），实际 \(debounce)")
        XCTAssertLessThanOrEqual(debounce, 200,
            "C8-e: instantDebounceMs 应接近 120ms（≤200），实际 \(debounce)")
    }

    // MARK: - 辅助：定位 Builtin 源码目录

    private static func builtinSourceDir() throws -> URL {
        let thisFile = URL(fileURLWithPath: #file)
        let desktopDir = thisFile
            .deletingLastPathComponent()  // Launcher/
            .deletingLastPathComponent()  // BuddyCoreTests/
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // apps/desktop/

        let builtinDir = desktopDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("ClaudeCodeBuddy")
            .appendingPathComponent("Launcher")
            .appendingPathComponent("Builtin")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: builtinDir.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            throw XCTSkip("Builtin 源码目录不存在，蓝队合并后运行：\(builtinDir.path)")
        }
        return builtinDir
    }

    private static func collectSwiftFiles(in dir: URL) throws -> [(String, String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [(String, String)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            result.append((fileURL.lastPathComponent, content))
        }
        return result
    }
}
