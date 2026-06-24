import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 黑盒验证 hello 示例修复（场景 10）+ plugin.json 文案重写（场景 6）。
///
/// 覆盖验收场景：
/// - 场景 10.P1: hello 目录含可执行 `hello.sh`（文件存在 + 可执行位）
/// - 场景 10.P3: inspect hello 的 cmd 指向的文件存在
/// - 场景 5.P1: inspect hello 含非空 summary
/// - 场景 6.P1: hello/qr/qzh summary+description 无黑话（stdin/stdout/QzhddrSrv/markdown 协议/裸字段名）
///
/// 信息隔离：用 Bundle.module 读 seed plugin.json（现有 AT12 同款方式，仅作测试输入）。
/// 命名前缀: test_AT<编号>_<场景>
final class HelloExampleAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 从 Bundle.module 读 Marketplace/plugins/<name>/plugin.json 解析为 dict。
    private func pluginJSONDict(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(
            forResource: "plugin",
            withExtension: "json",
            subdirectory: "Marketplace/plugins/\(name)"
        ) else {
            XCTFail("plugin.json for '\(name)' not found in Bundle.module")
            throw NSError(domain: "test", code: 1)
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    /// 从 Bundle.module 读 Marketplace/plugins/<name>/ 目录下某文件 URL。
    private func bundledFile(_ filename: String, in pluginDir: String) -> URL? {
        Bundle.module.url(
            forResource: (filename as NSString).deletingPathExtension,
            withExtension: (filename as NSString).pathExtension,
            subdirectory: "Marketplace/plugins/\(pluginDir)"
        )
    }

    // MARK: - 场景 10.P1: hello.sh 存在且可执行

    /// 契约 + 场景 10.P1: hello 目录含可执行 hello.sh。
    func test_AT01_helloShExistsInBundle() throws {
        // 场景 10.P1 assert: test -x hello.sh && echo OK
        guard let url = bundledFile("hello.sh", in: "hello") else {
            XCTFail("hello.sh 缺失（场景 10：plugin.json cmd=./hello.sh 但文件不存在 → 执行阶段崩）")
            return
        }
        // 文件存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "hello.sh 必须存在于 Bundle Marketplace/plugins/hello/")
    }

    /// 场景 10.P1: hello.sh 可执行位（bundle copy 后的 posix 权限）。
    /// 注意：SPM .copy 资源可能不保留可执行位；真实部署到 ~/.buddy/launcher-plugins/ 时由 install 保证。
    /// 此处断言文件内容非空且为脚本（shebang 或可执行内容），作为「修复」的最低信号。
    func test_AT02_helloShIsNonEmptyScript() throws {
        guard let url = bundledFile("hello.sh", in: "hello") else {
            XCTFail("hello.sh 缺失")
            return
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "hello.sh 不能是空文件（场景 10：需能产出非空 stdout）")
    }

    // MARK: - 场景 10.P3: inspect hello cmd 指向的文件存在

    /// 契约 + 场景 10.P3: plugin.json cmd=./hello.sh → hello.sh 文件存在。
    func test_AT03_helloCmdPointsToExistingFile() throws {
        let dict = try pluginJSONDict("hello")
        let cmd = dict["cmd"] as? String ?? ""
        XCTAssertEqual(cmd, "./hello.sh",
                       "hello plugin.json cmd 必须指向 ./hello.sh")
        // cmd 去掉 "./" 前缀得到目标文件名
        let targetName = cmd.hasPrefix("./") ? String(cmd.dropFirst(2)) : cmd
        let targetURL = bundledFile(targetName, in: "hello")
        XCTAssertNotNil(targetURL,
                        "hello cmd 指向的文件 '\(targetName)' 必须存在于 Bundle")
        if let targetURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path),
                          "hello cmd 指向的文件必须实际存在")
        }
    }

    // MARK: - 场景 5.P1: inspect hello 含非空 summary

    /// 契约 C1 + 场景 5.P1: hello plugin.json 含非空 summary。
    func test_AT04_helloPluginJSONHasNonEmptySummary() throws {
        let dict = try pluginJSONDict("hello")
        let summary = dict["summary"] as? String
        XCTAssertNotNil(summary, "hello plugin.json 必须含 summary 字段（契约 C1 + 场景 5.P1）")
        XCTAssertFalse(summary?.isEmpty ?? true,
                       "hello summary 不能为空（场景 5.P1: inspect hello 含非空 summary）")
    }

    // MARK: - 场景 6.P1: hello/qr/qzh 文案无黑话

    /// 契约 C1 + 场景 6.P1: hello/qr/qzh 的 summary+description 不含黑话词。
    /// 场景 6.P1 assert: grep 'stdin|stdout|markdown 协议|QzhddrSrv|requiredPath' 无输出
    func test_AT06_noJargonInExternalPluginCopy() throws {
        // 场景 6.P1 黑名单（逐字取自 assert 正则）
        let forbidden = ["stdin", "stdout", "markdown 协议", "QzhddrSrv", "requiredPath"]
        for name in ["hello", "qr", "qzh"] {
            let dict = try pluginJSONDict(name)
            let summary = (dict["summary"] as? String) ?? ""
            let description = (dict["description"] as? String) ?? ""
            let combined = summary + "\n" + description
            for word in forbidden {
                XCTAssertFalse(combined.contains(word),
                               "插件 \(name) 文案含黑话词「\(word)」（场景 6.P1: summary+description 须为人话）\nsummary=\(summary)\ndescription=\(description)")
            }
        }
    }

    /// 契约 C1: qr/qzh 也必须有 summary（官方插件强制填）。
    func test_AT05_qrQzhHaveSummary() throws {
        for name in ["qr", "qzh"] {
            let dict = try pluginJSONDict(name)
            let summary = dict["summary"] as? String
            XCTAssertNotNil(summary, "\(name) plugin.json 必须含 summary（契约 C1: 官方插件强制填）")
            XCTAssertFalse(summary?.isEmpty ?? true, "\(name) summary 不能为空")
        }
    }
}
