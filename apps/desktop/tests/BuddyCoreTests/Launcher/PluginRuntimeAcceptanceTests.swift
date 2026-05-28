import XCTest
@testable import BuddyCore

// MARK: - PluginRuntimeAcceptanceTests
//
// 验收测试：PluginManager（list/find/pluginDir/installBundledPlugins）+
//           StdinExecutor（execute + 子进程完整生命周期）
//
// 设计文档覆盖点（task 004 输出契约）：
//   Manager.list 行为：
//     MA1. rootDir 不存在 → 返回 []（不抛错）
//     MA2. 3 目录（valid/no-manifest/bad-json）→ list() 仅返回 1 个
//     MA3. rootDir 含文件而非目录 → 跳过
//     MA4. list 返回的 manifest 字段与 plugin.json 完全一致
//
//   Manager.find / pluginDir：
//     MB1. find("name") 返回对应 manifest（Equatable 精确比较）
//     MB2. find("nonexistent") 返回 nil（不抛错）
//     MB3. pluginDir 匹配 dirName==manifest.name（builtin-hello 直接路径）
//     MB4. pluginDir 次选 dirName.hasSuffix("-name")（user-repo 后缀匹配，manifest.name="repo"）
//     MB5. pluginDir 两者均不匹配 → 抛 LauncherError.pluginNotFound
//
//   StdinExecutor.execute 真实子进程：
//     E1. 正例：fixture 脚本输出 "## Hello"，exit 0 → exitCode==0，stdout=="## Hello\n"
//     E2. stdin 传递：cat 脚本回显 stdin，stdout 含 "\"query\":\"hi\""
//     E3. exit code 非 0：exit 2 + stderr="err msg" → 抛 pluginCrash(2, content 含 "err msg")
//     E4. 超时 SIGKILL：trap TERM 忽略 + sleep 30，timeout=1 → 抛 pluginTimeout(1)；耗时 ≤ 8s
//     E5. 依赖缺失：requiredPath=["nonexistent-binary-zzz-xxx"] → 抛 pluginMissingDependency；
//         marker 文件不存在（进程未启动）
//     E6. stdout 截断：输出 2 MiB → stdout 长度 ≤ 1 MiB+尾部 "[...output truncated]"；
//         stdoutTruncated==true
//     E7. PATH 注入：echo PATH 脚本 → stdout 含 "/opt/homebrew/bin"
//
//   bundled HelloPlugin 集成：
//     H1. installBundledPlugins() → builtin-hello/ 存在 + 含 plugin.json + hello.sh
//     H2. hello.sh 权限 == 0o755
//     H3. execute(builtin-hello, input{query:"world"}) → stdout 含 "## Hello, world!"
//
// 测试隔离：文件操作使用 NSTemporaryDirectory + UUID，tearDown 清理。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// MARK: - PluginManagerAcceptanceTests

final class PluginManagerAcceptanceTests: XCTestCase {

    private var tmpDir: URL!
    private var manager: PluginManager!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "PluginManagerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        manager = PluginManager(rootDir: tmpDir)
    }

    override func tearDown() async throws {
        if let dir = tmpDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpDir = nil
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writePluginJSON(_ content: String, inDir dirName: String) throws -> URL {
        let dir = tmpDir.appending(path: dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "plugin.json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeValidPluginJSON(
        name: String,
        cmd: String = "./run.sh"
    ) -> String {
        """
        {
          "name": "\(name)",
          "version": "1.0.0",
          "description": "test",
          "keywords": ["test"],
          "cmd": "\(cmd)",
          "args": [],
          "env": null,
          "timeout": 5,
          "requiredPath": null
        }
        """
    }

    // MARK: - MA1. rootDir 不存在 → 返回 []

    /// rootDir 不存在时 list() 必须返回空数组，不抛错。
    func test_list_rootDirNotExists_returnsEmpty() throws {
        let nonExistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "NonExistentDir-\(UUID().uuidString)")
        let mgr = PluginManager(rootDir: nonExistent)

        let result = try mgr.list()

        XCTAssertEqual(result.count, 0,
                       "rootDir 不存在时 list() 必须返回空数组，实际: \(result.count) 个")
    }

    // MARK: - MA2. 3 目录（valid / no-manifest / bad-json）→ list() 仅返回 1 个

    /// valid/no-manifest/bad-json 三个目录 → list() 返回 1 个，跳过 2 个无效目录。
    func test_list_threeDirectories_returnsOnlyValidManifest() throws {
        // valid 目录：合法 plugin.json（name 与 dirName 匹配）
        try writePluginJSON(makeValidPluginJSON(name: "valid"), inDir: "valid")

        // no-manifest 目录：无 plugin.json
        let noManifestDir = tmpDir.appending(path: "no-manifest")
        try FileManager.default.createDirectory(at: noManifestDir, withIntermediateDirectories: true)

        // bad-json 目录：非法 JSON
        let badDir = tmpDir.appending(path: "bad-json")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "{ this is not valid json !! }".write(
            to: badDir.appending(path: "plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try manager.list()

        XCTAssertEqual(result.count, 1,
                       "3 个目录中只有 1 个合法，list() 必须精确返回 1 个，实际: \(result.count)")
        XCTAssertEqual(result[0].name, "valid",
                       "返回的 manifest name 必须精确是 'valid'，实际: \(result[0].name)")
    }

    // MARK: - MA3. rootDir 含文件而非目录 → 跳过

    /// rootDir 中放一个普通文件时，list() 必须跳过，不抛错。
    func test_list_plainFile_skipped() throws {
        // 先放一个合法插件目录
        try writePluginJSON(makeValidPluginJSON(name: "real-plugin"), inDir: "real-plugin")

        // 再放一个普通文件（非目录）
        let filePath = tmpDir.appending(path: "not-a-directory.json")
        try "{}".write(to: filePath, atomically: true, encoding: .utf8)

        let result = try manager.list()

        XCTAssertEqual(result.count, 1,
                       "含有普通文件时，list() 应只返回合法插件目录，实际: \(result.count)")
        XCTAssertEqual(result[0].name, "real-plugin",
                       "返回的 manifest name 必须精确是 'real-plugin'")
    }

    // MARK: - MA4. list 返回的 manifest 字段与 plugin.json 完全一致

    /// list() 返回的 manifest 的各字段必须与 plugin.json 精确一致。
    func test_list_manifestFields_matchPluginJSON() throws {
        let json = """
        {
          "name": "my-plugin",
          "version": "3.2.1",
          "description": "My test plugin",
          "keywords": ["alpha", "beta"],
          "cmd": "./run.py",
          "args": ["-v", "--json"],
          "env": {"FOO": "BAR"},
          "timeout": 45,
          "requiredPath": ["python3"]
        }
        """
        try writePluginJSON(json, inDir: "my-plugin")

        let result = try manager.list()

        XCTAssertEqual(result.count, 1,
                       "只有一个合法目录，list() 必须返回 1 个")
        let m = result[0]
        XCTAssertEqual(m.name, "my-plugin")
        XCTAssertEqual(m.version, "3.2.1")
        XCTAssertEqual(m.description, "My test plugin")
        XCTAssertEqual(m.keywords, ["alpha", "beta"])
        XCTAssertEqual(m.cmd, "./run.py")
        XCTAssertEqual(m.args, ["-v", "--json"])
        XCTAssertEqual(m.env, ["FOO": "BAR"])
        XCTAssertEqual(m.timeout, 45)
        XCTAssertEqual(m.requiredPath, ["python3"])
    }

    // MARK: - MB1. find("name") 返回对应 manifest

    /// find("valid") 必须返回 name=="valid" 的 manifest。
    func test_find_existingPlugin_returnsManifest() throws {
        try writePluginJSON(makeValidPluginJSON(name: "valid"), inDir: "valid")

        let result = try manager.find(name: "valid")

        XCTAssertNotNil(result, "find('valid') 必须返回 manifest，不应返回 nil")
        XCTAssertEqual(result?.name, "valid",
                       "find('valid') 返回的 manifest.name 必须精确是 'valid'")
    }

    // MARK: - MB2. find("nonexistent") 返回 nil

    /// find("nonexistent") 必须返回 nil，不抛错。
    func test_find_nonExistentPlugin_returnsNil() throws {
        // 不创建任何目录
        let result = try manager.find(name: "nonexistent")

        XCTAssertNil(result, "find('nonexistent') 必须返回 nil，不应抛错")
    }

    // MARK: - MB3. pluginDir 匹配 dirName==manifest.name（直接匹配）

    /// 当 dirName 与 manifest.name 完全相同时，pluginDir 返回该路径。
    func test_pluginDir_directNameMatch_returnsCorrectURL() throws {
        try writePluginJSON(makeValidPluginJSON(name: "builtin-hello"), inDir: "builtin-hello")
        let manifest = PluginManifest(
            name: "builtin-hello",
            version: "1.0.0",
            description: "test",
            keywords: [],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: nil,
            requiredPath: nil
        )

        let dir = try manager.pluginDir(for: manifest)

        XCTAssertEqual(dir.lastPathComponent, "builtin-hello",
                       "pluginDir 直接匹配时 lastPathComponent 必须精确是 'builtin-hello'")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "pluginDir 返回的路径必须确实存在")
    }

    // MARK: - MB4. pluginDir 次选后缀匹配（user-repo, manifest.name="repo"）

    /// dirName="user-repo"，manifest.name="repo" → pluginDir 通过后缀匹配返回 user-repo 目录。
    func test_pluginDir_suffixMatch_returnsCorrectURL() throws {
        try writePluginJSON(makeValidPluginJSON(name: "repo"), inDir: "user-repo")
        let manifest = PluginManifest(
            name: "repo",
            version: "1.0.0",
            description: "test",
            keywords: [],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: nil,
            requiredPath: nil
        )

        let dir = try manager.pluginDir(for: manifest)

        XCTAssertEqual(dir.lastPathComponent, "user-repo",
                       "pluginDir 后缀匹配时 lastPathComponent 必须精确是 'user-repo'")
    }

    // MARK: - MB5. pluginDir 两者均不匹配 → 抛 pluginNotFound

    /// 没有匹配目录时 pluginDir 必须抛 LauncherError.pluginNotFound。
    func test_pluginDir_noMatch_throwsPluginNotFound() throws {
        // 创建一个不匹配的目录
        try writePluginJSON(makeValidPluginJSON(name: "other"), inDir: "other")
        let manifest = PluginManifest(
            name: "missing",
            version: "1.0.0",
            description: "test",
            keywords: [],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: nil,
            requiredPath: nil
        )

        XCTAssertThrowsError(
            try manager.pluginDir(for: manifest),
            "找不到匹配目录时 pluginDir 必须抛 LauncherError.pluginNotFound"
        ) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginNotFound，实际: \(error)")
                return
            }
            XCTAssertEqual(name, "missing",
                           "pluginNotFound 关联值必须精确是 'missing'，实际: \(name)")
        }
    }
}

// MARK: - PluginExecutorAcceptanceTests

final class PluginExecutorAcceptanceTests: XCTestCase {

    private var tmpDir: URL!
    private var executor: StdinExecutor!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "PluginExecutorTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        executor = StdinExecutor()
    }

    override func tearDown() async throws {
        if let dir = tmpDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpDir = nil
        executor = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeScript(_ content: String, named name: String = "run.sh") throws -> URL {
        let url = tmpDir.appending(path: name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeManifest(
        name: String = "test",
        cmd: String = "./run.sh",
        timeout: Int? = 5,
        requiredPath: [String]? = nil,
        env: [String: String]? = nil
    ) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: "test",
            keywords: [],
            cmd: cmd,
            args: [],
            env: env,
            timeout: timeout,
            requiredPath: requiredPath
        )
    }

    private func makeInput(query: String = "test-query") -> PluginInput {
        PluginInput(
            query: query,
            sessionId: UUID().uuidString,
            cwd: "/tmp"
        )
    }

    // MARK: - E1. 正例：exit 0，stdout 精确

    /// fixture 脚本输出 "## Hello"，exit 0 → exitCode==0，stdout=="## Hello\n"，
    /// stderr==""，durationMs < 5000，stdoutTruncated==false。
    func test_execute_successScript_returnsCorrectResult() async throws {
        let scriptContent = """
        #!/bin/bash
        echo "## Hello"
        exit 0
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 5)

        let result = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())

        XCTAssertEqual(result.exitCode, 0,
                       "exit 0 的脚本 exitCode 必须精确是 0，实际: \(result.exitCode)")
        XCTAssertEqual(result.stdout, "## Hello\n",
                       "stdout 必须精确是 '## Hello\\n'，实际: \(result.stdout.debugDescription)")
        XCTAssertEqual(result.stderr, "",
                       "无 stderr 输出时 stderr 必须精确是空字符串，实际: \(result.stderr.debugDescription)")
        XCTAssertFalse(result.stdoutTruncated,
                       "stdout 未超 1 MiB 时 stdoutTruncated 必须是 false")
        XCTAssertLessThan(result.durationMs, 5000,
                          "正常 exit 0 脚本 durationMs 必须 < 5000ms，实际: \(result.durationMs)ms")
    }

    // MARK: - E2. stdin 传递：cat 回显 stdin，含 JSON 字段

    /// fixture 脚本 `cat` 回显 stdin → stdout 必须含 `"query":"hi"` 字符串。
    func test_execute_stdinPassthrough_queryAppearsInStdout() async throws {
        let scriptContent = """
        #!/bin/bash
        cat
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 5)
        let input = PluginInput(
            query: "hi",
            sessionId: UUID().uuidString,
            cwd: "/tmp"
        )

        let result = try await executor.execute(manifest, pluginDir: tmpDir, input: input)

        XCTAssertTrue(
            result.stdout.contains("\"query\"") && result.stdout.contains("hi"),
            "cat 回显 stdin 时 stdout 必须含 query 字段和值 'hi'，实际: \(result.stdout.debugDescription)"
        )
        // 更精确：JSON 编码后应含 "query":"hi"（key/value 对）
        XCTAssertTrue(
            result.stdout.contains("\"query\":\"hi\"") || result.stdout.contains("\"query\": \"hi\""),
            "stdout 应含 '\"query\":\"hi\"'，实际: \(result.stdout.debugDescription)"
        )
    }

    // MARK: - E3. exit code 非 0 → 抛 pluginCrash

    /// fixture 脚本 exit 2 + stderr="err msg" → 抛 LauncherError.pluginCrash(2, content 含 "err msg")。
    func test_execute_nonZeroExitCode_throwsPluginCrash() async throws {
        let scriptContent = """
        #!/bin/bash
        echo "err msg" >&2
        exit 2
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 5)

        do {
            _ = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())
            XCTFail("exit code 非 0 时必须抛 LauncherError.pluginCrash，未抛错")
        } catch {
            guard case LauncherError.pluginCrash(let code, let stderrContent) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginCrash，实际: \(error)")
                return
            }
            XCTAssertEqual(code, 2,
                           "pluginCrash 关联值 code 必须精确是 2，实际: \(code)")
            XCTAssertTrue(stderrContent.contains("err msg"),
                          "pluginCrash 关联值必须含 stderr 内容 'err msg'，实际: \(stderrContent.debugDescription)")
        }
    }

    // MARK: - E4. 超时 SIGKILL → 抛 pluginTimeout；耗时 ≤ 8s

    /// fixture 脚本 `trap '' TERM; sleep 30`，timeout=1 → 抛 pluginTimeout(1)；总耗时 ≤ 8s。
    func test_execute_timeout_throwsPluginTimeoutWithinGrace() async throws {
        let scriptContent = """
        #!/bin/bash
        trap '' TERM
        sleep 10
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 1)

        let startTime = Date()
        do {
            _ = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())
            XCTFail("超时脚本必须抛 LauncherError.pluginTimeout，未抛错")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            guard case LauncherError.pluginTimeout(let timeoutSec) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginTimeout，实际: \(error)")
                return
            }
            XCTAssertEqual(timeoutSec, 1,
                           "pluginTimeout 关联值必须精确是 1（manifest timeout），实际: \(timeoutSec)")
            // 1s timeout + 5s SIGKILL grace + 2s 余量 = 8s 总上限
            XCTAssertLessThanOrEqual(elapsed, 8.0,
                                     "超时+SIGKILL 流程总耗时必须 ≤ 8s，实际: \(String(format: "%.2f", elapsed))s")
        }
    }

    // MARK: - E5. 依赖缺失 → 抛 pluginMissingDependency；进程未启动

    /// manifest.requiredPath=["nonexistent-binary-zzz-xxx"] → 抛 pluginMissingDependency；
    /// 验证进程未启动：fixture 脚本写 marker 文件，marker 不存在则进程确未启动。
    func test_execute_missingDependency_throwsMissingDependency_processNotStarted() async throws {
        let markerFile = tmpDir.appending(path: "started-marker.txt")

        // fixture 脚本：如果被执行，会写一个 marker 文件
        let scriptContent = """
        #!/bin/bash
        touch "\(markerFile.path)"
        echo "this ran"
        exit 0
        """
        try writeScript(scriptContent)

        let uniqueBinary = "nonexistent-binary-zzz-\(UUID().uuidString)"
        let manifest = makeManifest(
            timeout: 5,
            requiredPath: [uniqueBinary]
        )

        do {
            _ = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())
            XCTFail("依赖缺失时必须抛 LauncherError.pluginMissingDependency，未抛错")
        } catch {
            guard case LauncherError.pluginMissingDependency(let binary) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginMissingDependency，实际: \(error)")
                return
            }
            XCTAssertEqual(binary, uniqueBinary,
                           "pluginMissingDependency 关联值必须精确是缺失的 binary 名，" +
                           "实际: \(binary)")

            // 验证进程未启动：marker 文件不应存在
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: markerFile.path),
                "依赖缺失时进程不应启动，marker 文件不应存在（进程未运行验证）"
            )
        }
    }

    // MARK: - E6. stdout 截断：2 MiB → stdoutTruncated==true，末尾含截断提示

    /// fixture 脚本输出 2 MiB → stdout 长度 ≤ 1 MiB；stdoutTruncated==true；末尾含 "[...output truncated]"。
    func test_execute_largeStdout_truncated() async throws {
        // 用 head -c 输出精确字节数。2 MiB = 2097152 字节
        // 注意：使用 Python 以避免 head -c 的 BSD/GNU 兼容问题
        let scriptContent = """
        #!/bin/bash
        python3 -c "import sys; sys.stdout.buffer.write(b'A' * 2097152)"
        exit 0
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 30)

        let result = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())

        let oneMiB = 1024 * 1024
        XCTAssertTrue(result.stdoutTruncated,
                      "2 MiB 输出时 stdoutTruncated 必须是 true")
        // stdout 字节长度 ≤ 1 MiB + 截断提示字符串长度（宽松上限 +100字节）
        XCTAssertLessThanOrEqual(
            result.stdout.utf8.count,
            oneMiB + 100,
            "stdout 截断后字节数必须 ≤ 1 MiB + 100（截断提示）"
        )
        XCTAssertTrue(
            result.stdout.hasSuffix("[...output truncated]"),
            "stdout 截断时末尾必须是 '[...output truncated]'，" +
            "实际末尾 50 字符: \(result.stdout.suffix(50).debugDescription)"
        )
    }

    // MARK: - E7. PATH 注入：stdout 含 "/opt/homebrew/bin"

    /// fixture 脚本输出 PATH 环境变量，验证 stdout 含 "/opt/homebrew/bin"。
    func test_execute_pathInjection_containsHomebrewBin() async throws {
        let scriptContent = """
        #!/bin/bash
        echo "PATH=$PATH"
        """
        try writeScript(scriptContent)
        let manifest = makeManifest(timeout: 5)

        let result = try await executor.execute(manifest, pluginDir: tmpDir, input: makeInput())

        XCTAssertTrue(
            result.stdout.contains("/opt/homebrew/bin"),
            "PATH 注入后 stdout 必须含 '/opt/homebrew/bin'，" +
            "实际: \(result.stdout.debugDescription)"
        )
    }
}

// MARK: - PluginBundledHelloAcceptanceTests

final class PluginBundledHelloAcceptanceTests: XCTestCase {

    private var tmpPluginsDir: URL!
    private var manager: PluginManager!
    private var executor: StdinExecutor!

    override func setUp() async throws {
        try await super.setUp()
        tmpPluginsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "BundledHelloTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpPluginsDir, withIntermediateDirectories: true)
        manager = PluginManager(rootDir: tmpPluginsDir)
        executor = StdinExecutor()
    }

    override func tearDown() async throws {
        if let dir = tmpPluginsDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpPluginsDir = nil
        manager = nil
        executor = nil
        try await super.tearDown()
    }

    // MARK: - H1. installBundledPlugins → builtin-hello/ 存在 + 含 plugin.json + hello.sh

    /// installBundledPlugins() 执行后 builtin-hello 目录存在，且含 plugin.json 和 hello.sh。
    func test_installBundledPlugins_createsBuiltinHelloDirectory() throws {
        try manager.installBundledPlugins()

        let builtinHelloDir = tmpPluginsDir.appending(path: "builtin-hello")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: builtinHelloDir.path),
            "installBundledPlugins 后 builtin-hello/ 目录必须存在，路径: \(builtinHelloDir.path)"
        )

        let pluginJSONPath = builtinHelloDir.appending(path: "plugin.json").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pluginJSONPath),
            "builtin-hello/ 必须含 plugin.json，路径: \(pluginJSONPath)"
        )

        let helloShPath = builtinHelloDir.appending(path: "hello.sh").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: helloShPath),
            "builtin-hello/ 必须含 hello.sh，路径: \(helloShPath)"
        )
    }

    // MARK: - H1b. installBundledPlugins 幂等

    /// 连续调用 installBundledPlugins 两次不应抛错（幂等验证）。
    func test_installBundledPlugins_idempotent_noThrow() throws {
        XCTAssertNoThrow(
            try manager.installBundledPlugins(),
            "第一次 installBundledPlugins 不应抛错"
        )
        XCTAssertNoThrow(
            try manager.installBundledPlugins(),
            "第二次 installBundledPlugins（幂等）不应抛错"
        )

        // 验证第二次调用后 plugin.json 仍存在
        let pluginJSONPath = tmpPluginsDir
            .appending(path: "builtin-hello")
            .appending(path: "plugin.json")
            .path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pluginJSONPath),
            "幂等调用后 plugin.json 必须仍存在"
        )
    }

    // MARK: - H2. hello.sh 权限 == 0o755

    /// installBundledPlugins 后 hello.sh 的 POSIX 权限必须精确是 0o755。
    func test_installBundledPlugins_helloShPermissions_755() throws {
        try manager.installBundledPlugins()

        let helloShURL = tmpPluginsDir
            .appending(path: "builtin-hello")
            .appending(path: "hello.sh")

        let attributes = try FileManager.default.attributesOfItem(atPath: helloShURL.path)
        let perms = attributes[.posixPermissions] as? Int

        XCTAssertEqual(perms, 0o755,
                       "hello.sh 权限必须精确是 0o755（可执行），" +
                       "实际: \(perms.map { String(format: "0o%o", $0) } ?? "nil")")
    }

    // MARK: - H3. execute builtin-hello，stdout 含 "## Hello, world!"

    /// installBundledPlugins + execute(manifest, input{query:"world"}) → stdout 含 "## Hello, world!"。
    func test_execute_builtinHello_stdoutContainsHelloWorld() async throws {
        try manager.installBundledPlugins()

        // 从 list() 获取 manifest（黑盒：不手动构造 manifest）
        let manifests = try manager.list()
        let manifest = manifests.first { $0.name == "builtin-hello" }
        let unwrappedManifest = try XCTUnwrap(
            manifest,
            "installBundledPlugins 后 list() 必须能找到 builtin-hello manifest"
        )

        let pluginDir = try manager.pluginDir(for: unwrappedManifest)
        let input = PluginInput(
            query: "world",
            sessionId: UUID().uuidString,
            cwd: "/tmp"
        )

        let result = try await executor.execute(unwrappedManifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0,
                       "builtin-hello exitCode 必须精确是 0，实际: \(result.exitCode)")
        XCTAssertTrue(
            result.stdout.contains("## Hello, world!"),
            "builtin-hello stdout 必须含 '## Hello, world!'，" +
            "实际: \(result.stdout.debugDescription)"
        )
        XCTAssertFalse(result.stdoutTruncated,
                       "builtin-hello 输出未超 1 MiB，stdoutTruncated 必须是 false")
    }

    // MARK: - H3b. builtin-hello manifest 字段契约

    /// installBundledPlugins 后从 list() 返回的 builtin-hello manifest 必须满足字段契约。
    func test_installBundledPlugins_manifestFields_matchDesignContract() throws {
        try manager.installBundledPlugins()

        let manifests = try manager.list()
        let manifest = manifests.first { $0.name == "builtin-hello" }
        let m = try XCTUnwrap(manifest, "list() 必须能找到 builtin-hello")

        XCTAssertEqual(m.name, "builtin-hello",
                       "builtin-hello manifest.name 必须精确是 'builtin-hello'")
        XCTAssertEqual(m.cmd, "./hello.sh",
                       "builtin-hello manifest.cmd 必须精确是 './hello.sh'")
        XCTAssertFalse(m.version.isEmpty,
                       "builtin-hello manifest.version 不应为空字符串")
        XCTAssertFalse(m.description.isEmpty,
                       "builtin-hello manifest.description 不应为空字符串")
        XCTAssertFalse(m.keywords.isEmpty,
                       "builtin-hello manifest.keywords 不应为空数组")
        // timeout 设计文档指定为 5
        XCTAssertEqual(m.timeout, 5,
                       "builtin-hello manifest.timeout 必须精确是 5，实际: \(String(describing: m.timeout))")
    }
}
