import XCTest
@testable import BuddyCore

// MARK: - CheckAndPromptIntegrationTests
//
// 蓝队单测 T8：集成回归——checkAndPrompt 默认参数路径 + 6 调用点签名兼容。
//
// 契约引用（state.md ## 实现计划 T8 + M5 真实签名不变）：
//   checkAndPrompt 真实签名对外不变（seam 参数有默认值），6 调用点（LauncherManager:443/615/819/920/1019 + QueryHandler:406）无需改动。
//   默认参数路径走 DependencyResolver.shared + DependencyInstaller.shared + TrustPrompt.askUserWithDeps。
//
// 测试策略：
// - 默认参数调用（2 参数形式，与生产调用点一致）在放行短路分支返回 true（不触发真实 NSAlert/brew）
// - 验证 6 调用点的方法引用类型兼容（编译期保证）

@MainActor
final class CheckAndPromptIntegrationTests: XCTestCase {

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckAndPromptIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutable(in dir: URL) throws -> URL {
        let exe = dir.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho hello".write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    // MARK: - 默认参数路径（放行短路，不触发真实 NSAlert）

    /// 契约 M5/T8：默认参数调用（2 参数形式）+ 已信任 + 无缺失 → 放行短路 return true。
    /// 此路径不触发真实 NSAlert（放行短路不弹框），可安全测试。
    func test_AT01_defaultArguments_passThroughShortCircuit() async throws {
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = PluginManifest(
            name: "integration-test", version: "0.1.0", description: "集成测试",
            keywords: [], cmd: "./run.sh", deps: []  // 无依赖
        )
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))
        try store.approve(plugin, executablePath: exe)  // 预信任

        // 默认参数调用（与生产 6 调用点形式一致：2 参数）
        let result = await store.checkAndPrompt(plugin, executablePath: exe)
        XCTAssertTrue(result, "默认参数 + 已信任 + 无缺失应放行短路")
    }

    /// 契约 T8：6 调用点方法引用类型兼容（编译期校验）。
    /// 生产调用点形式：`await TrustStore.shared.checkAndPrompt(plugin, executablePath: exe)`。
    func test_AT02_callSiteForm_compiles() async throws {
        // 此测试只需编译通过（方法签名可达），运行时短路不弹框。
        let dir = try makeTmpDir()
        let exe = try makeExecutable(in: dir)
        let plugin = PluginManifest(
            name: "callsite-test", version: "0.1.0", description: "调用点",
            keywords: [], cmd: "./run.sh"
        )
        let store = TrustStore(file: dir.appendingPathComponent("trust.json"))
        try store.approve(plugin, executablePath: exe)

        // 模拟 6 调用点的精确调用形式
        let trusted = await store.checkAndPrompt(plugin, executablePath: exe)
        XCTAssertTrue(trusted)
    }
}
