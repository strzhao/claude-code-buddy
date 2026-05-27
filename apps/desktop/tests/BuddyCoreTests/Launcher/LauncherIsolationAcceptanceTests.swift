import XCTest
import Foundation
@testable import BuddyCore

// MARK: - LauncherIsolationAcceptanceTests
//
// 红队验收测试：SC-10 "Launcher 与像素猫互不干扰"
//
// 测试角度（与蓝队 LauncherIsolationTests 互补，不重复）：
//   方法 1 — 路径不冲突反例：
//       buddyDir 旗下所有已知路径 vs 像素猫已知路径集合 hashSet intersection
//   方法 2 — 类型依赖反向验证：
//       grep Launcher 源码目录全部 .swift 文件，断言无 forbidden symbol
//   方法 3 — Launcher 配置目录前缀隔离：
//       buddyDir 必须以 NSHomeDirectory() 开头（用户态），而非 /tmp
//   方法 4 — 缓存/socket 路径常量审计：
//       扫描全 Launcher 源码无 "/tmp/claude-buddy" 硬编码字符串
//
// 说明：这四个测试均为静态/编译期 or 文件系统扫描，不依赖运行时 NSApp / dev server。
// 红队红线：不读蓝队本次实现的 LauncherIsolationTests.swift 或新增实现文件。

final class LauncherIsolationAcceptanceTests: XCTestCase {

    // MARK: - 方法 1: 路径 hashSet 交集必须为空
    //
    // SC-10 子契约：Launcher 文件全部落在 ~/.buddy/，像素猫路径在 /tmp/，
    // 路径字符串集合取交集必须为空（严格不重叠）。

    func test_SC10_pathNamespace_launcherAndPixelCat_noIntersection() {
        // Launcher 已知路径集合（取 path 字符串）
        let launcherPaths: Set<String> = [
            LauncherConstants.buddyDir.path,
            LauncherConstants.launcherConfigPath.path,
            LauncherConstants.encryptedSecretsPath.path,
            LauncherConstants.launcherPluginsDir.path,
            // trust.json 的默认路径
            LauncherConstants.buddyDir.appendingPathComponent("launcher-trust.json").path,
        ]

        // 像素猫子系统已知路径（SOURCE-OF-TRUTH 来自 SocketServer.swift / SessionManager.swift）
        let pixelCatPaths: Set<String> = [
            "/tmp/claude-buddy.sock",
            "/tmp/claude-buddy-colors.json",
            "/tmp/claude-buddy-click.log",
        ]

        // 精确字符串交集
        let intersection = launcherPaths.intersection(pixelCatPaths)
        XCTAssertTrue(
            intersection.isEmpty,
            "SC-10 违反：Launcher 路径与像素猫路径出现交集 → \(intersection)，两个子系统必须路径完全隔离"
        )

        // 附加：前缀包含检查（防止路径一方是另一方的父目录）
        for lp in launcherPaths {
            for pp in pixelCatPaths {
                XCTAssertFalse(
                    lp.hasPrefix(pp) || pp.hasPrefix(lp),
                    "SC-10 违反：Launcher 路径 '\(lp)' 与像素猫路径 '\(pp)' 存在前缀包含关系（目录包含）"
                )
            }
        }
    }

    // MARK: - 方法 2: Launcher 源码中无 forbidden 像素猫符号引用
    //
    // SC-10 子契约：类型依赖隔离——Launcher 公共 API 文件不能 import 或调用
    // 像素猫子系统的类型（SessionManager / BuddyScene / CatSprite /
    // FoodManager / BuddyEvent / SocketServer）。
    //
    // 实现：读取 Launcher 目录下所有 .swift 文件内容，grep forbidden 关键字。

    func test_SC10_launcherSources_noDependencyOn_pixelCatTypes() throws {
        let launcherSourceDir = try Self.launcherSourceDir()

        // 收集所有 .swift 文件内容
        let swiftFiles = try Self.collectSwiftFiles(in: launcherSourceDir)
        XCTAssertFalse(swiftFiles.isEmpty, "Launcher 源码目录为空，测试无效：\(launcherSourceDir.path)")

        // 禁止出现的像素猫符号（精确类名 / 枚举名）
        let forbiddenSymbols = [
            "SessionManager",
            "BuddyScene",
            "CatSprite",
            "FoodManager",
            "BuddyEvent",
            "SocketServer",
        ]

        for (filePath, content) in swiftFiles {
            for symbol in forbiddenSymbols {
                XCTAssertFalse(
                    content.contains(symbol),
                    "SC-10 违反：Launcher 源文件 '\(filePath)' 引用了像素猫符号 '\(symbol)'，类型依赖必须完全隔离"
                )
            }
        }
    }

    // MARK: - 方法 3: buddyDir 前缀必须是 NSHomeDirectory()（用户态），非 /tmp
    //
    // SC-10 子契约：Launcher 配置目录必须是用户态路径（~/.buddy/），
    // 不能误落入 /tmp（系统临时目录，像素猫领域）。

    func test_SC10_buddyDir_prefixIsHomeDir_notTmp() {
        let buddyDirPath = LauncherConstants.buddyDir.path
        let homeDir = NSHomeDirectory()

        // 必须以 home 目录开头
        XCTAssertTrue(
            buddyDirPath.hasPrefix(homeDir),
            "SC-10 违反：buddyDir 必须以 NSHomeDirectory() '\(homeDir)' 开头（用户态路径），实际: '\(buddyDirPath)'"
        )

        // 绝对不能以 /tmp 开头
        XCTAssertFalse(
            buddyDirPath.hasPrefix("/tmp"),
            "SC-10 违反：buddyDir 不能以 '/tmp' 开头（/tmp 是像素猫领域），实际: '\(buddyDirPath)'"
        )

        // trust.json 路径同样验证
        let trustPath = LauncherConstants.buddyDir.appendingPathComponent("launcher-trust.json").path
        XCTAssertTrue(
            trustPath.hasPrefix(homeDir),
            "SC-10 违反：trust.json 路径必须在 home 目录下，实际: '\(trustPath)'"
        )
        XCTAssertFalse(
            trustPath.hasPrefix("/tmp"),
            "SC-10 违反：trust.json 路径不能在 /tmp 下，实际: '\(trustPath)'"
        )
    }

    // MARK: - 方法 4: Launcher 源码无 "/tmp/claude-buddy" 硬编码字符串
    //
    // SC-10 子契约：缓存/socket 路径常量审计——任何 Launcher 模块文件不得
    // 硬编码像素猫的 /tmp 路径字面量，防止误用或意外耦合。

    func test_SC10_launcherSources_noHardcodedPixelCatTmpPaths() throws {
        let launcherSourceDir = try Self.launcherSourceDir()
        let swiftFiles = try Self.collectSwiftFiles(in: launcherSourceDir)
        XCTAssertFalse(swiftFiles.isEmpty, "Launcher 源码目录为空，测试无效：\(launcherSourceDir.path)")

        // 像素猫路径前缀（完全匹配这些字面量即违反隔离）
        let forbiddenPathLiterals = [
            "/tmp/claude-buddy",
        ]

        for (filePath, content) in swiftFiles {
            for literal in forbiddenPathLiterals {
                XCTAssertFalse(
                    content.contains(literal),
                    "SC-10 违反：Launcher 源文件 '\(filePath)' 硬编码了像素猫路径字面量 '\(literal)'，禁止在 Launcher 模块中出现"
                )
            }
        }
    }

    // MARK: - 辅助：定位 Launcher 源码目录

    /// 从测试 bundle 路径反向定位 Sources/ClaudeCodeBuddy/Launcher/ 目录
    private static func launcherSourceDir() throws -> URL {
        // 测试文件位于 Tests/BuddyCoreTests/Launcher/，从 Bundle.main 或文件路径推算
        // 采用相对于测试源文件的策略：利用 #file 宏定位
        let thisFile = URL(fileURLWithPath: #file)
        // 从 tests/BuddyCoreTests/Launcher/ 上溯 4 层到 apps/desktop/，再进入 Sources
        let desktopDir = thisFile
            .deletingLastPathComponent()  // Launcher/
            .deletingLastPathComponent()  // BuddyCoreTests/
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // apps/desktop/
        let launcherDir = desktopDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("ClaudeCodeBuddy")
            .appendingPathComponent("Launcher")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: launcherDir.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            throw XCTSkip("Launcher 源码目录不存在（构建环境中可能已被打包），跳过源码扫描：\(launcherDir.path)")
        }
        return launcherDir
    }

    /// 递归收集目录下所有 .swift 文件的（相对路径, 文件内容）
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
