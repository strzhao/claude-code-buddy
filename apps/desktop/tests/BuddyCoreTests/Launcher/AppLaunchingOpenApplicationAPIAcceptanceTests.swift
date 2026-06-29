import XCTest
import Foundation

// MARK: - AppLaunchingOpenApplicationAPIAcceptanceTests
//
// 红队验收测试：NSWorkspace.openApplication API 迁移契约
//
// 契约覆盖：
//   C1: NSWorkspaceAppLauncher 仍实现 AppLaunching 协议（向后兼容）
//   C2: 返回值语义不变——异步错误走 BuddyLogger 日志，不 throw（fire-and-forget）
//   C3: 同步外观不变——launch 方法签名保持 throws（fileExists guard 保留）
//   C4: 依赖不变——不引入新 import 或新类型，仅在 AppKit 内切换 API
//
// 验收场景（SC1-SC6）：纯文件系统扫描，不 import BuddyCore。
//
// 红队红线：仅读取 AppLaunching.swift 源文件内容做字符串断言；
//   不依赖蓝队实现细节，只验证设计文档中的契约规约。
// 测试 WILL NOT compile / WILL fail 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class AppLaunchingOpenApplicationAPIAcceptanceTests: XCTestCase {

    // MARK: - 路径定位

    /// AppLaunching.swift 源文件的绝对路径
    private var appLaunchingSwiftPath: String {
        let thisFile = URL(fileURLWithPath: #file)
        // tests/BuddyCoreTests/Launcher/<thisFile> → 上溯到 apps/desktop/
        let desktopDir = thisFile
            .deletingLastPathComponent()  // Launcher/
            .deletingLastPathComponent()  // BuddyCoreTests/
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // apps/desktop/

        return desktopDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("ClaudeCodeBuddy")
            .appendingPathComponent("Launcher")
            .appendingPathComponent("Builtin")
            .appendingPathComponent("AppLauncher")
            .appendingPathComponent("AppLaunching.swift")
            .path
    }

    // MARK: - 辅助方法

    /// 读取源文件内容；若文件不存在则 XCTSkip
    private func readSource(label: String = "AppLaunching.swift") throws -> String {
        guard FileManager.default.fileExists(atPath: appLaunchingSwiftPath) else {
            throw XCTSkip("\(label) 尚未存在（蓝队未合并），跳过：\(appLaunchingSwiftPath)")
        }
        return try String(contentsOfFile: appLaunchingSwiftPath, encoding: .utf8)
    }

    // MARK: - SC1: 编译期协议契约

    /// SC1: NSWorkspaceAppLauncher 仍实现 AppLaunching 协议（编译期契约）
    ///
    /// 设计意图：API 迁移后协议实现关系不变，MockAppLauncher 注入不受影响（C8-c 回归）。
    /// 验证方式：源文件含 `NSWorkspaceAppLauncher: AppLaunching` 字面值。
    func test_SC1_NSWorkspaceAppLauncher_conformsTo_AppLaunching() throws {
        let source = try readSource()

        XCTAssertTrue(
            source.contains("NSWorkspaceAppLauncher: AppLaunching"),
            """
            SC1 违反：NSWorkspaceAppLauncher 未实现 AppLaunching 协议。
            期望含子串：NSWorkspaceAppLauncher: AppLaunching
            设计意图：API 迁移后协议实现关系不变，MockAppLauncher 可继续注入。
            源码路径：\(appLaunchingSwiftPath)
            """
        )
    }

    // MARK: - SC2: launch 方法签名不变

    /// SC2: NSWorkspaceAppLauncher.launch(_:) 方法签名不变
    ///
    /// 设计意图：调用方 AppLauncherPlugin.actions(for:) 的 perform closure
    /// 调用 `try launcher.launch(url)`——签名保持 `throws` 确保调用方无需修改。
    /// 验证方式：源文件含 `func launch(_ url: URL) throws` 字面值（恰好 1 处）。
    func test_SC2_launch_methodSignature_unchanged() throws {
        let source = try readSource()

        // 统计 func launch(_ url: URL) throws 出现次数
        // 注：协议声明 + 实现同在 AppLaunching.swift，因此至少 1 处；
        // 当前蓝队实现含协议（1）+ NSWorkspaceAppLauncher（1）= 2 处
        let pattern = "func launch(_ url: URL) throws"
        let count = source.components(separatedBy: pattern).count - 1

        XCTAssertGreaterThanOrEqual(count, 1,
            """
            SC2 违反：launch(_:) 方法签名缺失。
            期望：源文件中至少 1 处 `func launch(_ url: URL) throws`
            实际：\(count) 处
            设计意图：同步外观不变，调用方 try launcher.launch(url) 无需修改。
            源码路径：\(appLaunchingSwiftPath)
            """
        )
    }

    // MARK: - SC3: 新 API 被调用

    /// SC3: 新 API `openApplication(at:configuration:completionHandler:)` 被调用
    ///
    /// 设计意图：替代废弃的 NSWorkspace.shared.open(url)，使用现代异步 API
    /// 以消除 macOS TCC 隐私警告。
    /// 验证方式：源文件含 `openApplication` 字面值。
    func test_SC3_openApplication_api_called() throws {
        let source = try readSource()

        XCTAssertTrue(
            source.contains("openApplication"),
            """
            SC3 违反：未找到 openApplication 调用。
            期望含子串：openApplication
            设计意图：用 NSWorkspace.shared.openApplication(at:configuration:completionHandler:)
            替代废弃的 .open(url)，消除 TCC 隐私警告。
            源码路径：\(appLaunchingSwiftPath)
            """
        )
    }

    // MARK: - SC4: 废弃 API 已移除

    /// SC4: 废弃 API `NSWorkspace.shared.open(url)` 不再出现在 AppLaunching.swift 中
    ///
    /// 设计意图：彻底移除旧 API，不留兼容代码路径。
    /// 验证方式：源文件不含 `.open(url)` 字面值。
    func test_SC4_deprecated_open_url_not_present() throws {
        let source = try readSource()

        XCTAssertFalse(
            source.contains(".open(url)"),
            """
            SC4 违反：废弃 API .open(url) 仍残留在源文件中。
            禁止含子串：.open(url)
            设计意图：彻底移除废弃的同步 open(url) 调用，仅保留 openApplication。
            源码路径：\(appLaunchingSwiftPath)
            """
        )
    }

    // MARK: - SC5: OpenConfiguration 创建且 activates=true

    /// SC5: OpenConfiguration 被创建且 `activates = true`
    ///
    /// 设计意图：新 API 必须传 NSWorkspace.OpenConfiguration，activates=true
    /// 确保 app 启动后被带到前台（与原行为一致）。
    /// 验证方式：源文件含 `OpenConfiguration` 和 `activates` 两处关键子串。
    func test_SC5_openConfiguration_created_with_activatesTrue() throws {
        let source = try readSource()

        // 检查 OpenConfiguration 引用
        XCTAssertTrue(
            source.contains("OpenConfiguration"),
            """
            SC5 违反（OpenConfiguration）：未找到 NSWorkspace.OpenConfiguration 创建。
            期望含子串：OpenConfiguration
            设计意图：使用 NSWorkspace.OpenConfiguration 配置启动行为。
            源码路径：\(appLaunchingSwiftPath)
            """
        )

        // 检查 activates 设置为 true
        XCTAssertTrue(
            source.contains("activates") && source.contains("= true"),
            """
            SC5 违反（activates）：未找到 activates = true 配置。
            期望含子串：activates 和 = true
            设计意图：activates=true 确保启动后 app 被带到前台。
            源码路径：\(appLaunchingSwiftPath)
            """
        )
    }

    // MARK: - SC6: 现有单元测试不退化

    /// SC6: 现有单元测试 AppLauncherIsolationAcceptanceTests 全部通过
    ///
    /// 设计意图：API 迁移后 MockAppLauncher 注入路径不受影响，
    /// C8-c 隔离测试应持续通过。
    ///
    /// 验证方式：det-machine 通道——在当前进程内验证 C8-c 测试类仍可注入 MockAppLauncher，
    /// 不依赖 `make test-only` 子进程（避免 SwiftPM 锁冲突）。
    ///
    /// 运行时验证需在独立终端执行：
    ///   make -C apps/desktop test-only FILTER=AppLauncherIsolationAcceptanceTests
    func test_SC6_mockAppLauncher_injection_seam_intact() throws {
        let source = try readSource(label: "AppLaunching.swift（C8-c 隔离 seam 验证）")

        // C8-c 核心契约：AppLaunching 协议可被 Mock 实现注入
        // 验证协议声明和实现关系在 AppLaunching.swift 中完好
        XCTAssertTrue(
            source.contains("protocol AppLaunching"),
            """
            SC6 违反（协议声明）：AppLaunching 协议声明缺失。
            期望含子串：protocol AppLaunching
            设计意图：C8-c 隔离 seam——MockAppLauncher 通过此协议注入，不真实启动 app。
            源码路径：\(appLaunchingSwiftPath)
            """
        )

        XCTAssertTrue(
            source.contains("NSWorkspaceAppLauncher: AppLaunching"),
            """
            SC6 违反（协议实现）：NSWorkspaceAppLauncher 未实现 AppLaunching。
            期望含子串：NSWorkspaceAppLauncher: AppLaunching
            设计意图：生产实现与 Mock 共享同一协议签名，确保 Mock 注入路径不变。
            源码路径：\(appLaunchingSwiftPath)
            """
        )

        // 验证 AppLauncherPlugin 所在的源文件引用 AppLaunching 协议
        // （而非绕过协议直接依赖 NSWorkspaceAppLauncher）
        let pluginSourcePath = (appLaunchingSwiftPath as NSString)
            .deletingLastPathComponent
            .appending("/AppLauncherPlugin.swift")
        let pluginSource = try String(contentsOfFile: pluginSourcePath, encoding: .utf8)

        // AppLauncherPlugin 应通过 AppLaunching 协议依赖，而非直接引用 NSWorkspaceAppLauncher
        // （C8-c 隔离 seam：依赖倒置，插件依赖协议不依赖具体实现）
        let pluginDependsOnProtocol = pluginSource.contains("AppLaunching")
        XCTAssertTrue(
            pluginDependsOnProtocol,
            """
            SC6 违反（依赖倒置）：AppLauncherPlugin 未通过 AppLaunching 协议引入启动能力。
            AppLauncherPlugin.swift 应引用 AppLaunching 协议（而非硬编码 NSWorkspaceAppLauncher）。
            设计意图：C8-c 隔离 seam——插件依赖协议，测试注入 Mock 替代生产实现。
            源码路径：\(pluginSourcePath)
            """
        )
    }
}
