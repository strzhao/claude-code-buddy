import XCTest
@testable import BuddyCore

// MARK: - StdinExecutorImageOutputTests
//
// 蓝队单测：StdinExecutor 通用图片通道（T3）—— stdin + command mode 共享
//
// 契约引用（state.md ## 契约规约 + 设计文档 §2）：
//   env["BUDDY_OUTPUT_IMAGE"] = "/tmp/buddy-plugin-<UUID>.png"
//   exit 0 后读文件 → Data → PluginResult.image
//   读前 resolvedPath == outputImagePath 校验（防 symlink）
//   count > pluginMaxImageBytes (= 5*1024*1024) → image = nil（丢弃）
//   文件不存在/读失败 → image = nil
//   finally 删临时文件
//
// TDD：先于实现编写，最初因 PluginResult.image 字段不存在编译失败（依赖 T4 先补字段）。

final class StdinExecutorImageOutputTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = StdinExecutor.shared

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StdinExecutorImage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 场景 1：子进程写 PNG 到 $BUDDY_OUTPUT_IMAGE → result.image 非空

    func test_imageChannel_childWritesPng_resultImageNonNil() async throws {
        // 用 shell 读 $BUDDY_OUTPUT_IMAGE 并写入 1x1 透明 PNG（完整，含 IEND chunk）
        let pngHex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c630001000000050001000000000049454e44ae426082"
        let script = """
        #!/bin/bash
        # 1x1 透明 PNG（base64 编码避免 shell 转义）
        printf '%s' "\(pngHex)" | xxd -r -p > "$BUDDY_OUTPUT_IMAGE"
        exit 0
        """
        let pluginDir = try makeScriptPlugin(dirName: "img-ok", manifestName: "img-ok", script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: "img-ok")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNotNil(result.image, "子进程写 PNG 后 result.image 必须非空")
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(image.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]), "image 必须以 PNG 魔数开头")
    }

    // MARK: - 场景 2：子进程不写文件 → result.image = nil（不报错）

    func test_imageChannel_childDoesNotWriteFile_resultImageNil() async throws {
        let script = """
        #!/bin/bash
        echo "text only"
        exit 0
        """
        let pluginDir = try makeScriptPlugin(dirName: "img-none", manifestName: "img-none", script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: "img-none")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.image, "子进程未写文件时 result.image 必须为 nil（降级非报错）")
        XCTAssertTrue(result.stdout.contains("text only"))
    }

    // MARK: - 场景 3：图片超过 pluginMaxImageBytes → image = nil（丢弃）

    func test_imageChannel_oversizedImage_dropped() async throws {
        // 写 6MB 数据（超过 5MB 上限）
        let script = """
        #!/bin/bash
        # 写 6MB（超过 5MiB 上限）
        dd if=/dev/zero of="$BUDDY_OUTPUT_IMAGE" bs=1048576 count=6 2>/dev/null
        exit 0
        """
        let pluginDir = try makeScriptPlugin(dirName: "img-big", manifestName: "img-big", script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: "img-big")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.image, "图片 > pluginMaxImageBytes 必须丢弃为 nil")
    }

    // MARK: - 场景 4：临时文件被 finally 清理

    func test_imageChannel_tempFileCleanedUpAfterExecution() async throws {
        let pngHex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63000100000005000100"
        let script = """
        #!/bin/bash
        printf '%s' "\(pngHex)" | xxd -r -p > "$BUDDY_OUTPUT_IMAGE"
        exit 0
        """
        let pluginDir = try makeScriptPlugin(dirName: "img-cleanup", manifestName: "img-cleanup", script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: "img-cleanup")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        // 执行完后 /tmp/buddy-plugin-*.png 应被清理（不随 N 累积，场景9.P1）
        let tmpContents = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        let leftover = tmpContents.filter { $0.hasPrefix("buddy-plugin-") && $0.hasSuffix(".png") }
        XCTAssertTrue(leftover.isEmpty, "临时 PNG 必须被 finally 清理，残留: \(leftover)")
    }

    // MARK: - 场景 5：BUDDY_OUTPUT_IMAGE env 路径格式符合契约

    func test_imageChannel_envPathFormat() async throws {
        // 用 env 捕获 $BUDDY_OUTPUT_IMAGE 到 stdout 供断言
        let script = """
        #!/bin/bash
        echo "PATH=$BUDDY_OUTPUT_IMAGE"
        exit 0
        """
        let pluginDir = try makeScriptPlugin(dirName: "img-env", manifestName: "img-env", script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: "img-env")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        let stdout = result.stdout
        guard let range = stdout.range(of: "PATH=") else {
            return XCTFail("stdout 应含 PATH= 行: \(stdout)")
        }
        let path = String(stdout[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasPrefix("/tmp/buddy-plugin-"),
                      "BUDDY_OUTPUT_IMAGE 必须以 /tmp/buddy-plugin- 开头，实际: \(path)")
        XCTAssertTrue(path.hasSuffix(".png"),
                      "BUDDY_OUTPUT_IMAGE 必须以 .png 结尾，实际: \(path)")
    }

    // MARK: - 场景 6：pluginMaxImageBytes 常量 = 5*1024*1024

    func test_pluginMaxImageBytes_constant() {
        XCTAssertEqual(LauncherConstants.pluginMaxImageBytes, 5 * 1024 * 1024,
                       "pluginMaxImageBytes 必须为 5*1024*1024")
    }

    // MARK: - Helpers

    private func makeScriptPlugin(
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
          "description": "test",
          "keywords": [],
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
