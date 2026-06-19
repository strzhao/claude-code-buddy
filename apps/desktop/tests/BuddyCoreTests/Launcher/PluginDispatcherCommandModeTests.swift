import XCTest
@testable import BuddyCore

// MARK: - PluginDispatcherCommandModeTests
//
// 蓝队单测：PluginDispatcher + LauncherManager command mode（T5）
//
// 契约引用（state.md ## 契约规约 + 设计文档 §4）：
//   PluginDispatcher.execute switch 加 .command → 转发 stdinExecutor（执行路径同 stdin）
//   LauncherManager.submit switch 加 .command（bypass agent loop，仿 prompt mode）
//
// 核心断言：
//   1. command manifest 经 dispatcher 执行，结果等价于直接调 stdinExecutor
//   2. command manifest 经 dispatcher 执行产 image（图片通道贯通）
//   3. dispatcher 对 command 不抛 promptExecutorNotAvailable（区别于 prompt mode）
//
// TDD：先于实现编写，最初因 PluginDispatcher 未处理 .command 编译失败（RED）。

final class PluginDispatcherCommandModeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DispatcherCommand-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 场景 1：command manifest 经 dispatcher 等价于直接调 stdinExecutor

    func test_commandManifest_dispatcherResult_equivalentToDirectStdinExecutor() async throws {
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-echo",
            manifestName: "cmd-echo",
            script: """
            #!/bin/bash
            echo "command ok"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-echo")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let executor = StdinExecutor()
        let dispatcher = PluginDispatcher(stdinExecutor: executor)

        let direct = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        let viaDispatcher = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(viaDispatcher.stdout, direct.stdout, "dispatcher 转发 command 应等价直接调 stdinExecutor")
        XCTAssertEqual(viaDispatcher.exitCode, direct.exitCode)
        XCTAssertEqual(viaDispatcher.image, direct.image)
        XCTAssertTrue(viaDispatcher.stdout.contains("command ok"))
    }

    // MARK: - 场景 2：command manifest 经 dispatcher 产 image（图片通道贯通）

    func test_commandManifest_dispatcherProduces_image() async throws {
        // 1x1 PNG（完整，含 IEND chunk）
        let pngHex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c630001000000050001000000000049454e44ae426082"
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-img",
            manifestName: "cmd-img",
            script: """
            #!/bin/bash
            printf '%s' "\(pngHex)" | xxd -r -p > "$BUDDY_OUTPUT_IMAGE"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-img")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNotNil(result.image, "command manifest 经 dispatcher 应产 image（图片通道贯通）")
        XCTAssertEqual(result.image?.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
    }

    // MARK: - 场景 3：command manifest 不抛 promptExecutorNotAvailable

    func test_commandManifest_doesNotRequirePromptExecutor() async throws {
        // promptExecutor 为 nil（默认），command 应正常执行不抛 promptExecutorNotAvailable
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-no-prompt",
            manifestName: "cmd-no-prompt",
            script: """
            #!/bin/bash
            echo "ok"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-no-prompt")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        // dispatcher 无 promptExecutor，command 不依赖它
        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor(), promptExecutor: nil)
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Helpers

    private func makeCommandPlugin(
        dirName: String,
        manifestName: String,
        script: String,
        timeout: Int = 10
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifestJSON = """
        {
          "name": "\(manifestName)",
          "version": "0.1.0",
          "description": "command mode test",
          "keywords": [],
          "mode": "command",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": null
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from pluginDir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }
}
