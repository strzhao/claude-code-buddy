import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - LauncherConstantsTask002AcceptanceTests
//
// 验收测试：LauncherConstants task 002 新增 6 个常量的精确值契约
//
// 设计文档覆盖点（task 002 LauncherConstants.swift 草图）：
//   A. keychainService == "claude-code-buddy.launcher"（精确字符串）
//   B. httpTimeoutSec == 120（TimeInterval 精确值）
//   C. minAPIKeyLength == 8（Int 精确值）
//   D. buddyDir.lastPathComponent == ".buddy"（路径末尾组件）
//   E. launcherConfigPath.lastPathComponent == "launcher.json"
//   F. encryptedSecretsPath.lastPathComponent == "launcher-secrets.enc"
//   G. buddyDir 是 launcherConfigPath 的父目录
//   H. buddyDir 是 encryptedSecretsPath 的父目录
//   I. launcherConfigPath 和 encryptedSecretsPath 都在 home 目录下的 .buddy 目录内
//
// 精确值断言：每个常量用 XCTAssertEqual 断言，不只是 XCTAssertNotNil。
// 这些常量是 CLI 和 app 共享的 SOURCE-OF-TRUTH，漂移会导致 CLI 写的 app 读不到。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherConstantsTask002AcceptanceTests: XCTestCase {

    // MARK: - A. keychainService 精确值

    /// Keychain service 名称必须精确是 "claude-code-buddy.launcher"
    /// 这是 CLI 和 app 共享的 source of truth，任何偏差导致无法互通
    func test_keychainService_exactValue() {
        XCTAssertEqual(
            LauncherConstants.keychainService,
            "claude-code-buddy.launcher",
            "keychainService 必须精确是 \"claude-code-buddy.launcher\"（CLI 和 app 共享）"
        )
    }

    // MARK: - B. httpTimeoutSec 精确值

    /// HTTP 超时必须精确是 120 秒（设计文档 DbC 约束：≤ 120s）
    func test_httpTimeoutSec_exactValue() {
        XCTAssertEqual(
            LauncherConstants.httpTimeoutSec,
            120,
            accuracy: 0.001,
            "httpTimeoutSec 必须精确是 120（TimeInterval）"
        )
    }

    // MARK: - C. minAPIKeyLength 精确值

    /// API key 最小长度必须精确是 8（设计文档 DbC：length >= 8）
    func test_minAPIKeyLength_exactValue() {
        XCTAssertEqual(
            LauncherConstants.minAPIKeyLength,
            8,
            "minAPIKeyLength 必须精确是 8（Int）"
        )
    }

    // MARK: - D. buddyDir.lastPathComponent == ".buddy"

    /// buddyDir 路径末尾组件必须是 ".buddy"
    func test_buddyDir_lastPathComponent_isDotBuddy() {
        XCTAssertEqual(
            LauncherConstants.buddyDir.lastPathComponent,
            ".buddy",
            "buddyDir.lastPathComponent 必须精确是 \".buddy\""
        )
    }

    /// buddyDir 必须是绝对路径（基于 home 目录）
    func test_buddyDir_isAbsolutePath() {
        XCTAssertTrue(
            LauncherConstants.buddyDir.path.hasPrefix("/"),
            "buddyDir 必须是绝对路径"
        )
    }

    // MARK: - E. launcherConfigPath.lastPathComponent == "launcher.json"

    /// launcherConfigPath 末尾组件必须精确是 "launcher.json"
    func test_launcherConfigPath_lastPathComponent_isLauncherJson() {
        XCTAssertEqual(
            LauncherConstants.launcherConfigPath.lastPathComponent,
            "launcher.json",
            "launcherConfigPath.lastPathComponent 必须精确是 \"launcher.json\""
        )
    }

    // MARK: - F. encryptedSecretsPath.lastPathComponent == "launcher-secrets.enc"

    /// encryptedSecretsPath 末尾组件必须精确是 "launcher-secrets.enc"
    func test_encryptedSecretsPath_lastPathComponent_isLauncherSecretsEnc() {
        XCTAssertEqual(
            LauncherConstants.encryptedSecretsPath.lastPathComponent,
            "launcher-secrets.enc",
            "encryptedSecretsPath.lastPathComponent 必须精确是 \"launcher-secrets.enc\""
        )
    }

    // MARK: - G. buddyDir 是 launcherConfigPath 的父目录

    /// launcherConfigPath 的 deletingLastPathComponent 必须等于 buddyDir
    func test_launcherConfigPath_parentIsbuddyDir() {
        let parent = LauncherConstants.launcherConfigPath.deletingLastPathComponent()
        XCTAssertEqual(
            parent.path,
            LauncherConstants.buddyDir.path,
            "launcherConfigPath 的父目录必须是 buddyDir"
        )
    }

    // MARK: - H. buddyDir 是 encryptedSecretsPath 的父目录

    /// encryptedSecretsPath 的 deletingLastPathComponent 必须等于 buddyDir
    func test_encryptedSecretsPath_parentIsBuddyDir() {
        let parent = LauncherConstants.encryptedSecretsPath.deletingLastPathComponent()
        XCTAssertEqual(
            parent.path,
            LauncherConstants.buddyDir.path,
            "encryptedSecretsPath 的父目录必须是 buddyDir"
        )
    }

    // MARK: - I. 路径在 home 目录下

    /// buddyDir 必须在用户 home 目录下
    func test_buddyDir_isUnderHomeDirectory() {
        let homeDir = NSHomeDirectory()
        XCTAssertTrue(
            LauncherConstants.buddyDir.path.hasPrefix(homeDir),
            "buddyDir 必须在用户 home 目录（\(homeDir)）下，" +
            "实际: \(LauncherConstants.buddyDir.path)"
        )
    }

    // MARK: - 边界值精确断言组

    /// minAPIKeyLength - 1 = 7 是边界外（拒绝）
    func test_minAPIKeyLength_boundaryCheck_7IsBelow() {
        let belowMinKey = String(repeating: "a", count: LauncherConstants.minAPIKeyLength - 1)
        XCTAssertEqual(belowMinKey.count, 7,
                       "minAPIKeyLength - 1 应该是 7 个字符（边界外，拒绝）")
    }

    /// minAPIKeyLength = 8 是最小合法长度
    func test_minAPIKeyLength_boundaryCheck_8IsAccepted() {
        let minKey = String(repeating: "a", count: LauncherConstants.minAPIKeyLength)
        XCTAssertEqual(minKey.count, 8,
                       "minAPIKeyLength 长度（8 字符）应该是最小合法 key")
    }

    // MARK: - 完整路径格式验证

    /// launcherConfigPath 完整路径格式验证（含 .buddy/launcher.json 结尾）
    func test_launcherConfigPath_endsWithBuddyLauncherJson() {
        let path = LauncherConstants.launcherConfigPath.path
        XCTAssertTrue(
            path.hasSuffix("/.buddy/launcher.json"),
            "launcherConfigPath 必须以 /.buddy/launcher.json 结尾，" +
            "实际: \(path)"
        )
    }

    /// encryptedSecretsPath 完整路径格式验证（含 .buddy/launcher-secrets.enc 结尾）
    func test_encryptedSecretsPath_endsWithBuddyLauncherSecretsEnc() {
        let path = LauncherConstants.encryptedSecretsPath.path
        XCTAssertTrue(
            path.hasSuffix("/.buddy/launcher-secrets.enc"),
            "encryptedSecretsPath 必须以 /.buddy/launcher-secrets.enc 结尾，" +
            "实际: \(path)"
        )
    }
}
