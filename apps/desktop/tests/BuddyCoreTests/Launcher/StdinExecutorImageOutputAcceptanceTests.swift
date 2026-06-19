import XCTest
import AppKit
@testable import BuddyCore

// MARK: - StdinExecutorImageOutputAcceptanceTests
//
// 红队验收测试：StdinExecutor 通用图片通道（BUDDY_OUTPUT_IMAGE env 注入 + 读文件 + 5MB 边界 + 清理）
//
// 设计文档引用：
//   .autopilot/runtime/sessions/qrcode/requirements/20260619-开始实现，图片通道认/state.md
//   ## 设计文档 §2 StdinExecutor 通用图片通道（stdin + command 共享）
//   ## 契约规约 边界值 invariant:
//     - 图片大小: PluginResult.image.count <= pluginMaxImageBytes (5 * 1024 * 1024)
//     - 临时文件路径: BUDDY_OUTPUT_IMAGE hasPrefix "/tmp/buddy-plugin-" AND hasSuffix ".png"
//     - 路径校验: resolvedPath == 注入路径（防 symlink）
//   ## 验收场景:
//     场景1.P3 [det-machine]: exit 0 → 读 BUDDY_OUTPUT_IMAGE → image 非空 + PNG 魔数
//     场景5.P1 [det-machine]: 超长输入不静默截断（negate: decoded != 截断）
//     场景6.P2 [det-machine]: 不完整 PNG（缺 IEND）被丢弃
//     场景8.P3 [det-machine]: env 含 BUDDY_OUTPUT_IMAGE 键
//     场景9.P1 [det-machine]: 临时文件清理（finally 删，N 次后有界）
//
// 黑盒策略：用真实 Process 跑 shell 脚本，脚本读 $BUDDY_OUTPUT_IMAGE 写文件。
// 不 mock StdinExecutor 内部 — 验完整 env 注入 → 子进程写 → 框架读 → PluginResult.image 流。
// 不读 StdinExecutor.swift 本次新增实现，仅依赖 PluginResult.image 字段契约。
// 测试 WILL NOT compile 直到蓝队 T3/T4 完成（pluginMaxImageBytes / PluginResult.image）。
//
// ⚠️ 铁律：本文件由红队独立编写，未读取蓝队实现代码。

final class StdinExecutorImageOutputAcceptanceTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = StdinExecutor.shared

    // MARK: - PNG fixtures

    /// 1x1 合法 PNG（含 IEND chunk），16 字节
    private let validPNG1x1: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG signature
        0x00, 0x00, 0x00, 0x0D,                            // IHDR length
        0x49, 0x48, 0x44, 0x52,                            // "IHDR"
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,   // width=1, height=1
        0x08, 0x06, 0x00, 0x00, 0x00,                      // bit depth, color type, crc...
        0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0D,
        0x49, 0x44, 0x41, 0x54,                            // "IDAT"
        0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00,
        0x49, 0x45, 0x4E, 0x44,                            // "IEND"
        0xAE, 0x42, 0x60, 0x82
    ])

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StdinImgAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        try await super.tearDown()
    }

    // MARK: - Plugin scaffolding

    /// 生成一个 stdin mode 插件，其 run.sh 把自定义字节流写入 $BUDDY_OUTPUT_IMAGE
    /// 用 base64 传字节避免 shell 转义问题
    private func makeStdinPlugin(
        dirName: String,
        imageBase64: String?,     // nil = 不写文件
        exitCode: Int32 = 0,
        timeout: Int = 30
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let writeLine: String
        if let b64 = imageBase64 {
            // shell 脚本：base64 解码后写入 $BUDDY_OUTPUT_IMAGE
            writeLine = """
            if [ -n \"$BUDDY_OUTPUT_IMAGE\" ]; then
              echo -n '\(b64)' | base64 -D > \"$BUDDY_OUTPUT_IMAGE\"
            fi
            """
        } else {
            writeLine = ": # do not write image"
        }

        let script = """
        #!/bin/bash
        \(writeLine)
        exit \(exitCode)
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifest = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "image output test",
          "keywords": [],
          "mode": "stdin",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": null
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("plugin.json"),
                          atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from dir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }

    // MARK: - 场景8.P3 [det-machine]: env 注入 BUDDY_OUTPUT_IMAGE 键
    //
    // 契约引用：StdinExecutor 注入 env BUDDY_OUTPUT_IMAGE
    // 黑盒验证：子进程能 echo 出该环境变量，证明框架注入了键
    // Mutation kill：若蓝队没注入 env，子进程 $BUDDY_OUTPUT_IMAGE 为空 → 断言挂

    func test_P8_3_envContainsBuddyOutputImageKey() async throws {
        // 用一个脚本打印 env 里 BUDDY_OUTPUT_IMAGE 的值到 stdout
        let pluginDir = tmpDir.appendingPathComponent("env-printer")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        echo "KEY=${BUDDY_OUTPUT_IMAGE:-MISSING}"
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "env-printer", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "stdin", "cmd": "./run.sh", "args": [], "env": null, "timeout": 30, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "env-printer")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertTrue(
            result.stdout.contains("KEY=/tmp/buddy-plugin-"),
            "子进程必须能读到 BUDDY_OUTPUT_IMAGE 键，且值以 /tmp/buddy-plugin- 开头。实际 stdout: \(result.stdout)"
        )
        // 场景8.P3 det-machine assert: env 含 BUDDY_OUTPUT_IMAGE 键
        XCTAssertFalse(
            result.stdout.contains("KEY=MISSING"),
            "BUDDY_OUTPUT_IMAGE 必须被注入（不能 MISSING），场景8.P3 失败"
        )
    }

    func test_P8_3_buddyOutputImagePathFormat() async throws {
        // 校验注入路径格式：hasPrefix "/tmp/buddy-plugin-" AND hasSuffix ".png"
        let pluginDir = tmpDir.appendingPathComponent("path-printer")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        echo "PATH=$BUDDY_OUTPUT_IMAGE"
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "path-printer", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "stdin", "cmd": "./run.sh", "args": [], "env": null, "timeout": 30, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "path-printer")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        // 抽取 PATH= 后的值
        let lines = result.stdout.split(separator: "\n")
        let pathLine = lines.first { $0.hasPrefix("PATH=/tmp/buddy-plugin-") }
        let path = try XCTUnwrap(pathLine, "必须能读到 PATH=/tmp/buddy-plugin-... 行")
        let value = String(path.dropFirst("PATH=".count))

        XCTAssertTrue(value.hasPrefix("/tmp/buddy-plugin-"),
                      "BUDDY_OUTPUT_IMAGE 必须 hasPrefix '/tmp/buddy-plugin-'，实际: \(value)")
        XCTAssertTrue(value.hasSuffix(".png"),
                      "BUDDY_OUTPUT_IMAGE 必须 hasSuffix '.png'，实际: \(value)")
    }

    // MARK: - 场景1.P3 [det-machine]: exit 0 → 读 BUDDY_OUTPUT_IMAGE → image 非空 + PNG 魔数 \x89PNG
    //
    // 契约引用：exit 0 → 读文件 → Data → PluginResult.image
    // 场景1.P3 assert: 文件 exists AND size>0 AND 头部匹配 PNG 魔数 \x89PNG

    func test_P1_3_exit0_readsBuddyOutputImage_pngMagicPresent() async throws {
        let pngB64 = validPNG1x1.base64EncodedString()
        let pluginDir = try makeStdinPlugin(dirName: "valid-png", imageBase64: pngB64)
        let manifest = try loadManifest(from: pluginDir, dirName: "valid-png")
        let input = PluginInput(query: "hello world", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0, "exit code 必须 0")
        let image = try XCTUnwrap(result.image,
                                  "场景1.P3 失败：exit 0 + 子进程写了 BUDDY_OUTPUT_IMAGE，PluginResult.image 必须非空")
        XCTAssertGreaterThan(image.count, 0, "image size 必须 > 0")

        // PNG 魔数 \x89PNG\r\n\x1a\n（8 字节签名）
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let head = Array(image.prefix(8))
        XCTAssertEqual(head, pngSignature,
                       "image 头部必须匹配 PNG 魔数 \\x89PNG，实际前 8 字节: \(head)")
    }

    // MARK: - 场景6.P2 [det-machine]: 不完整 PNG（缺 IEND）被丢弃
    //
    // 契约引用：文件不存在/读失败/count > pluginMaxImageBytes → image=nil（降级，不报错）
    // 扩展契约（设计文档场景6.P2）：仅 IEND 完整时渲染否则丢弃
    // 黑盒：构造无 IEND 的 PNG 字节流，断言 image == nil

    func test_P6_2_incompletePNG_missingIEND_isDiscarded() async throws {
        // 从合法 PNG 移除最后 8 字节（IEND chunk + crc），造一个不完整 PNG
        var truncated = validPNG1x1
        truncated.removeLast(8)
        // 确保头部仍是合法 PNG 签名（让蓝队若只查签名会通过，必须查 IEND 才能挂）
        XCTAssertEqual(Array(truncated.prefix(4)), [0x89, 0x50, 0x4E, 0x47],
                       "fixture 头部必须是 PNG 签名")
        // fixture sanity：IEND 字节序列必须已被移除（否则测试无效）
        let iendBytes = Data([0x49, 0x45, 0x4E, 0x44])  // "IEND"
        XCTAssertNil(truncated.range(of: iendBytes),
                     "fixture sanity：IEND 字节序列必须被移除（否则无法验证丢弃逻辑）")

        let b64 = truncated.base64EncodedString()
        let pluginDir = try makeStdinPlugin(dirName: "truncated-png", imageBase64: b64)
        let manifest = try loadManifest(from: pluginDir, dirName: "truncated-png")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)

        // 场景6.P2 det-machine assert: 仅 IEND 完整时渲染否则丢弃
        XCTAssertNil(result.image,
                     "场景6.P2 失败：缺 IEND 的不完整 PNG 必须被丢弃（image == nil），实际: \(String(describing: result.image))")
    }

    // MARK: - 边界值：image.count > pluginMaxImageBytes 丢弃
    //
    // 契约引用：边界值 example — image.count > 5MB → PluginResult.image = nil

    func test_imageSize_exceedsMaxBytes_isDiscarded() async throws {
        // 构造 5MB + 1 字节的假 PNG（头是合法签名，超量）
        let pluginMaxBytes = LauncherConstants.pluginMaxImageBytes
        var oversized = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        oversized.append(Data(repeating: 0x00, count: pluginMaxBytes + 1))
        let b64 = oversized.base64EncodedString()
        let pluginDir = try makeStdinPlugin(dirName: "oversized-png", imageBase64: b64)
        let manifest = try loadManifest(from: pluginDir, dirName: "oversized-png")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.image,
                     "image.count > pluginMaxImageBytes (=\(pluginMaxBytes)) 必须被丢弃，实际: \(String(describing: result.image?.count))")
    }

    func test_pluginMaxImageBytes_equals5MiB() {
        // 契约 invariant: pluginMaxImageBytes = 5 * 1024 * 1024
        // 防蓝队写错常量值
        XCTAssertEqual(
            LauncherConstants.pluginMaxImageBytes,
            5 * 1024 * 1024,
            "pluginMaxImageBytes 必须 = 5 * 1024 * 1024 (5 MiB)"
        )
    }

    // MARK: - 场景9.P1 [det-machine]: 临时文件清理（finally 删，N 次后有界）
    //
    // 契约引用：defer/finally 删临时文件
    // 场景9.P1 assert: N 次后临时 PNG 数 <= 上限，不随 N 线性增长
    // 黑盒：执行 N 次，扫 /tmp 下 buddy-plugin-*.png 计数必须不随 N 增长

    func test_P9_1_tempFileCleaned_afterMultipleRuns() async throws {
        // 先清掉既存 buddy-plugin-*.png（其他测试可能残留），记基准
        let tmpRoot = "/tmp"
        let baseline = try countBuddyPluginPngs(in: tmpRoot)

        let pngB64 = validPNG1x1.base64EncodedString()
        let pluginDir = try makeStdinPlugin(dirName: "cleanup-test", imageBase64: pngB64)
        let manifest = try loadManifest(from: pluginDir, dirName: "cleanup-test")

        let N = 5
        for i in 0..<N {
            let input = PluginInput(query: "round-\(i)", sessionId: UUID().uuidString, cwd: "/tmp")
            _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        }

        let after = try countBuddyPluginPngs(in: tmpRoot)

        // 场景9.P1 assert: N 次后临时 PNG 数 <= 上限（= baseline，不随 N 线性增长）
        XCTAssertLessThanOrEqual(
            after,
            baseline + 1,  // 允许 1 个残留容忍（并发/时序），但绝不 +N
            "场景9.P1 失败：\(N) 次执行后 /tmp 下 buddy-plugin-*.png 数 = \(after)，基准 \(baseline)。" +
            "若 finally 清理生效，应 <= baseline+1，绝不应 ~baseline+\(N)"
        )
    }

    private func countBuddyPluginPngs(in dir: String) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        return files.filter { $0.hasPrefix("buddy-plugin-") && $0.hasSuffix(".png") }.count
    }

    // MARK: - 场景5.P1 [det-machine] 间接：超长输入不静默截断（negate: decoded != 截断）
    //
    // 契约引用：场景5.P1 negate — decoded != 截断输入
    // 这里的 "decoded" 指二维码解码后的 payload；qr-gen 实现在 plugins/qr/qr-gen.swift。
    // 本文件测框架层（StdinExecutor）：框架必须把完整 query 透传给子进程 stdin（PluginInput.query 不截断）。
    // qr-gen 端到端解码在 QrPluginAcceptanceTests 验。

    func test_P5_1_framework_passesFullQueryToStdin_notTruncated() async throws {
        // 构造超长 query（远超二维码容量），脚本 echo 出收到的字节数到 stderr
        // 证明框架没在 stdin 阶段截断 query
        let longQuery = String(repeating: "a", count: 5000)
        let pluginDir = tmpDir.appendingPathComponent("echo-length")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // 脚本：从 stdin 读全部字节，输出字节数到 stderr
        let script = """
        #!/bin/bash
        INPUT=$(cat)
        echo -n "${#INPUT}" > /tmp/buddy-echo-len-$$
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "echo-length", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "stdin", "cmd": "./run.sh", "args": [], "env": null, "timeout": 30, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "echo-length")
        let input = PluginInput(query: longQuery, sessionId: UUID().uuidString, cwd: "/tmp")
        _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        // 找到 echo 写的长度文件
        let tmpFiles = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        let lenFile = tmpFiles.first { $0.hasPrefix("buddy-echo-len-") }
        let lenPath = try XCTUnwrap(lenFile, "子进程必须写了 /tmp/buddy-echo-len-* 长度文件")
        let lenStr = try String(contentsOfFile: "/tmp/\(lenPath)", encoding: .utf8)
        try? FileManager.default.removeItem(atPath: "/tmp/\(lenPath)")

        // 子进程收到的 stdin 字节数应 == PluginInput JSON 编码后长度（远 > longQuery.count，因为 JSON 包装）
        // negate: 若框架截断 query，lenStr 会远小于预期
        let receivedLen = Int(lenStr) ?? -1
        XCTAssertGreaterThanOrEqual(
            receivedLen,
            longQuery.count,
            "场景5.P1 negate：框架必须把完整 query 透传给子进程（receivedLen=\(receivedLen) 应 >= \(longQuery.count)），" +
            "若框架截断 query，receivedLen 会 << longQuery.count"
        )
    }
}
