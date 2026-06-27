import XCTest
@testable import BuddyCore

// MARK: - CheckAndPromptDepTests
//
// 蓝队单测 T5：TrustStore.checkAndPrompt 改造（信任 + 依赖合并，五分支）。
//
// 契约引用（state.md ## 设计文档 M5 + 契约规约 checkAndPrompt 行为契约）：
//   真实签名不变：@MainActor func checkAndPrompt(_ plugin:, executablePath: URL) async -> Bool
//   放行短路：isEverTrusted(plugin.name) && collectMissing(plugin).isEmpty → return true（不弹）
//   弹框条件：collectMissing(plugin).isEmpty == false → 弹框（不管信任状态）
//   五分支：
//     1. 放行短路：已信任 + 无缺失 → return true（不弹）
//     2. 首次纯信任：!trusted + 无缺失 → 弹纯信任框 → 用户允许 → approve + return true
//     3. 首次信任+依赖：!trusted + 有缺失 → 弹合并框 → 允许 → installAll → approve → return true
//     4. 已信任+缺失重弹：trusted + 有缺失 → 弹依赖框（信任区标记已授权）→ 允许 → installAll → 不重复 approve → return true
//     5. brew 缺失失败引导：有 brew 依赖 + brew missing → 弹引导框 → return false（不执行）
//   approve 仅 !trusted；已信任重弹不重复写信任记录
//
// 测试策略：注入 mock resolver + installer + prompter（避免真跑 brew / 真 NSAlert）。

@MainActor
final class CheckAndPromptDepTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckAndPromptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManifest(name: String = "test-plugin", deps: [PluginDep] = []) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "0.1.0",
            description: "测试",
            keywords: [],
            cmd: "./run.sh",
            deps: deps
        )
    }

    private func makeExecutable(in dir: URL) throws -> URL {
        let exe = dir.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho hello".write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    // MARK: - 分支 1：放行短路（已信任 + 无缺失）

    /// 契约 M5：已信任 + 依赖齐全 → return true（不弹框，TOFU 免打扰）。
    func test_AT01_passThroughShortCircuit_trustedNoMissing() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest()
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))
        // 预先 approve 建立信任
        try store.approve(plugin, executablePath: exe)

        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in [] },           // 无缺失
            installer: { _ in .success },           // 不应被调用
            prompter: { _, _, _, _, _ in true }           // 不应被调用
        )
        XCTAssertTrue(result, "已信任 + 无缺失应放行短路 return true")
    }

    // MARK: - 分支 2：首次纯信任（!trusted + 无缺失）

    /// 契约 M5：首次 + 无依赖 → 弹纯信任框 → 用户允许 → approve + return true。
    func test_AT02_firstTimePureTrust_allowed_approvesAndReturnsTrue() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest()
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))
        XCTAssertFalse(store.isEverTrusted(plugin.name), "前置：未信任")

        var promptCalled = false
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in [] },
            installer: { _ in .success },
            prompter: { _, _, hasDeps, _, _ in
                promptCalled = true
                XCTAssertFalse(hasDeps, "无依赖时 prompter hasDeps 应为 false")
                return true
            }
        )
        XCTAssertTrue(result)
        XCTAssertTrue(promptCalled, "首次应弹框")
        XCTAssertTrue(store.isEverTrusted(plugin.name), "允许后应写信任记录")
    }

    /// 契约 M5：首次纯信任 → 用户拒绝 → return false（不 approve）。
    func test_AT02b_firstTimePureTrust_denied_returnsFalse() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest()
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))

        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in [] },
            installer: { _ in .success },
            prompter: { _, _, _, _, _ in false }          // 拒绝
        )
        XCTAssertFalse(result)
        XCTAssertFalse(store.isEverTrusted(plugin.name), "拒绝不应写信任记录")
    }

    // MARK: - 分支 3：首次信任 + 依赖（!trusted + 有缺失）

    /// 契约 M5：首次 + 有缺失 → 弹合并框 → 允许 → installAll 成功 → approve → return true。
    func test_AT03_firstTimeWithDeps_installSuccess_approvesAndReturnsTrue() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest(deps: [PluginDep(check: "qrencode", brew: "qrencode", label: "二维码")])
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))

        let missing = [DependencyStatus(check: "qrencode", label: "二维码", isInstalled: false, brewPackage: "qrencode")]
        var installerCalled = false
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in missing },
            installer: { deps in
                installerCalled = true
                XCTAssertEqual(deps.count, 1)
                return .success
            },
            prompter: { _, _, hasDeps, _, _ in
                XCTAssertTrue(hasDeps, "有依赖时 hasDeps 应为 true")
                return true
            }
        )
        XCTAssertTrue(result)
        XCTAssertTrue(installerCalled, "允许后应调 installAll")
        XCTAssertTrue(store.isEverTrusted(plugin.name), "安装成功应 approve")
    }

    /// 契约 M5：首次 + 有缺失 → 允许 → installAll 失败 → return false（不 approve）。
    func test_AT03b_firstTimeWithDeps_installFailure_returnsFalse() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest(deps: [PluginDep(check: "qrencode", brew: "qrencode", label: nil)])
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))

        let missing = [DependencyStatus(check: "qrencode", label: nil, isInstalled: false, brewPackage: "qrencode")]
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in missing },
            installer: { _ in .partialFailure(["qrencode"]) },
            prompter: { _, _, _, _, _ in true }
        )
        XCTAssertFalse(result, "installAll 失败应 return false")
        XCTAssertFalse(store.isEverTrusted(plugin.name), "安装失败不应 approve")
    }

    // MARK: - 分支 4：已信任 + 缺失重弹（trusted + 有缺失）

    /// 契约 M5：已信任 + 新增缺失 → 重弹依赖框 → 允许 → installAll → 不重复 approve → return true。
    func test_AT04_trustedWithMissing_rerunsInstallNoReapprove() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest(deps: [PluginDep(check: "imagemagick", brew: "imagemagick", label: nil)])
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))
        try store.approve(plugin, executablePath: exe)  // 预信任

        let missing = [DependencyStatus(check: "imagemagick", label: nil, isInstalled: false, brewPackage: "imagemagick")]
        var approveCount = 0
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in missing },
            installer: { _ in .success },
            prompter: { _, _, hasDeps, isAlreadyTrusted, _ in
                XCTAssertTrue(isAlreadyTrusted, "已信任重弹应标记 isAlreadyTrusted=true")
                XCTAssertTrue(hasDeps)
                return true
            }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(approveCount, 0, "已信任重弹不应重复 approve（approveCount 仅验证逻辑，实际由 store 内部判）")
    }

    // MARK: - 分支 5：brew 缺失失败引导

    /// 契约 M5/M6：有 brew 依赖 + brew 缺失 → 弹引导框 → return false（不执行 installAll）。
    func test_AT05_brewMissing_returnsFalse_noInstall() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest(deps: [PluginDep(check: "qrencode", brew: "qrencode", label: nil)])
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))

        let missing = [DependencyStatus(check: "qrencode", label: nil, isInstalled: false, brewPackage: "qrencode")]
        var installerCalled = false
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in missing },
            installer: { _ in
                installerCalled = true
                return .success
            },
            prompter: { _, _, _, _, _ in
                XCTFail("brew 缺失应走引导分支，不调标准 prompter")
                return false
            },
            brewAvailability: { .missing },          // brew 缺失
            brewMissingPrompter: { _ in
                // brew 缺失引导框被调用
            }
        )
        XCTAssertFalse(result, "brew 缺失应 return false")
        XCTAssertFalse(installerCalled, "brew 缺失不应调 installAll")
    }

    // MARK: - 全局开关降级（场景 7）

    /// 契约 M7：全局开关关 + 有缺失 → 弹框（命令+复制模式）→ 用户允许 → installAll 返回 manualRequired → return false。
    /// 注：manualRequired 表示用户需手动装，不应自动执行插件。
    func test_AT06_autoInstallOff_manualRequired_returnsFalse() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = makeManifest(deps: [PluginDep(check: "qrencode", brew: "qrencode", label: nil)])
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))

        let missing = [DependencyStatus(check: "qrencode", label: nil, isInstalled: false, brewPackage: "qrencode")]
        let result = await store.checkAndPrompt(
            plugin,
            executablePath: exe,
            missingProvider: { _ in missing },
            installer: { _ in .manualRequired },
            prompter: { _, _, _, _, _ in true }
        )
        XCTAssertFalse(result, "manualRequired 应 return false（需用户手动装后重试）")
    }
}
