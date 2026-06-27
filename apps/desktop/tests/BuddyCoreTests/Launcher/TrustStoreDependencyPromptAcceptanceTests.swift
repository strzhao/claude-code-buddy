import XCTest
@testable import BuddyCore

// MARK: - TrustStoreDependencyPromptAcceptanceTests
//
// 红队验收测试（shimmering-bubbling-bonbon，依赖合并权限弹框，2026-06-25）
//
// 覆盖模块：M5 (T5) TrustStore.checkAndPrompt 改造（信任 + 依赖合并，含新增依赖重弹）
//          M6 (T5) brew 缺失处理
// 覆盖契约（state.md ## 契约规约）：
//   - 接口签名：func checkAndPrompt(_ plugin: PluginManifest, executablePath: URL) async -> Bool
//     (@MainActor，真实签名不变，mode 信息在 plugin.modeConfig)
//   - checkAndPrompt 行为契约（DbC）：
//     放行条件（invariant）：isEverTrusted(plugin.name)==true AND collectMissing(plugin).isEmpty==true → return true（不弹）
//     弹框条件：collectMissing(plugin).isEmpty==false（有缺失，不管信任状态）→ 弹框
//     首次（!trusted）：信任授权 + 依赖区（若有缺失）
//     已信任（trusted && missing 非空）：依赖安装，不重复授权
//     approve 写记录：仅 !trusted；已信任重弹不重复写
//   - 错误契约：
//     collectMissing 非空 + brew missing → checkAndPrompt 返回 false（点 2 直接失败，弹框引导 brew.sh）
//     副作用：打开 URL NSWorkspace.open("https://brew.sh")（brew 缺失引导时）
//
// 覆盖验收场景：
//   - 场景 1：qr 首次 + 缺 qrencode → 合并弹框 + 一键安装 → 装后执行（1.P1/1.P4 det-machine）
//   - 场景 2：qr 已信任 + 依赖齐 → 不弹直接执行（2.P1 det-machine，negate: 弹框不应出现）
//   - 场景 3：qr 已信任 + 新增 imagemagick 缺失 → 重弹只装新依赖（3.P3/3.P4 negate）
//   - 场景 4：qr 已信任 + qrencode 卸载 → 重弹（4.P1/4.P2 negate）
//   - 场景 5：无依赖插件首次 → 简洁信任框（5.P1 negate: 依赖区不应出现）
//   - 场景 6：brew 缺失 → 失败 + 引导 brew.sh（6.P2/6.P3 det-machine，negate: qr 不应执行）
//
// seam 设计（红队视角）：
// checkAndPrompt 真实签名含 NSAlert runModal（UI），单测层需注入决策点。
//
// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
//   蓝队 checkAndPrompt 真实签名（5 闭包 seam，均有默认值）：
//     @MainActor func checkAndPrompt(
//       _ plugin: PluginManifest, executablePath: URL,
//       missingProvider: (PluginManifest) -> [DependencyStatus] = {...},
//       installer: ([DependencyStatus]) async -> InstallResult = {...},
//       prompter: (PluginManifest, URL, Bool, Bool, [DependencyStatus]) async -> Bool = {...},
//       brewAvailability: () -> BrewAvailability = {...},
//       brewMissingPrompter: ([DependencyStatus]) async -> Void = {...}
//     ) async -> Bool
//   红队原假设的 prompt/resolver/installer/workspace 对象注入适配为闭包：
//     - MockResolver(missing:) → missingProvider: { _ in mock.missing }
//     - MockInstaller(result:) → installer: { missing in mockInstaller.installAll(missing) }
//     - MockTrustPrompt(decision) → prompter: { _,_,_,_,_ in decision }
//     - brewAvailable:Bool → brewAvailability: { flag ? .available(path:) : .missing }
//   断言值（allowed/isEverTrusted/record count/capturedMissing）原样保留。
//
// NSWorkspace.open（场景 6.P2 OST）：蓝队 TrustPrompt.showBrewMissingGuide 直接调
//   NSWorkspace.shared.open(url)（无 seam 可注入），单测无法 mock 系统单例。
//   该断言标 VISUAL_RESIDUE 留 QA 真机判定；brewMissingPrompter 闭包被调作间接断言保留。
//
// 红队红线：不读 Sources/ClaudeCodeBuddy/Launcher/TrustStore.swift / TrustPrompt.swift 等蓝队实现，
// 仅依据 state.md 的「## 契约规约 + ## 设计文档 M5/M6 + 验收场景」黑盒断言。

@MainActor
final class TrustStoreDependencyPromptAcceptanceTests: XCTestCase {

    // MARK: - Fixtures / Helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustDepPrompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func writeExecutable(content: String = "#!/bin/sh\necho hi") throws -> URL {
        let exe = tempDir.appendingPathComponent("run.sh")
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    /// 构造 qr manifest（command mode + deps）
    private func makeQRManifest(deps: String) -> PluginManifest {
        let json = """
        {"name":"qr","version":"0.1.0","description":"qr","keywords":["qr"],
         "mode":"command","cmd":"./qr-gen.sh","args":[],
         "deps":\(deps)}
        """
        return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
    }

    private func makeQRManifestDeps(missingChecks: [String]) -> PluginManifest {
        let depsJSON = missingChecks.map { check in
            "{\"check\":\"\(check)\",\"brew\":\"\(check)\",\"label\":\"\(check)库\"}"
        }.joined(separator: ",")
        return makeQRManifest(deps: "[" + depsJSON + "]")
    }

    private func makeNoDepsManifest(name: String = "translate") -> PluginManifest {
        // 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
        // prompt mode 必须含 systemPrompt（蓝队 PluginManifest init(from:) 强制 decode），
        // 红队原 fixture 缺 systemPrompt → decode 崩溃。补 systemPrompt 不改场景语义（测「无依赖首次信任」）。
        let json = """
        {"name":"\(name)","version":"0.1.0","description":"\(name)","keywords":["\(name)"],
         "mode":"prompt","systemPrompt":"translate helper","maxIterations":1,"cmd":"./run.sh","args":[]}
        """
        return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
    }

    // MARK: - 场景 2 / 放行短路: isEverTrusted + 无缺失 → return true（不弹）

    /// 契约 M5 行为契约 / 场景 2.P1：放行条件（invariant）
    /// `isEverTrusted(plugin.name)==true AND collectMissing(plugin).isEmpty==true → return true（不弹）`。
    ///
    /// 对应 P#：场景 2.P1（已信任 + 依赖齐 → 不弹直接执行，negate: 弹框不应出现）。
    /// Mutation-Survival：若实现漏掉 collectMissing.isEmpty 检查（只看 isEverTrusted），
    /// 有缺失时也会 return true，本测试用「无缺失」仍能过；但下一个测试（场景 3）会挂。
    func test_M5_passThroughShortCircuit_trustedAndNoMissing_returnsTrueNoPrompt() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeNoDepsManifest(name: "trusted-no-deps")

        // 预先 approve（建立信任）
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isEverTrusted("trusted-no-deps"))

        // checkAndPrompt：已信任 + 无缺失 → 放行短路（显式注入空 missingProvider 确定性）
        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [] }
        )
        XCTAssertTrue(allowed,
                      "已信任 + 依赖齐 → checkAndPrompt 必须 return true（放行短路，场景 2）")
    }

    // MARK: - 场景 1 / 首次纯信任: !trusted + 无缺失 → 弹信任框，用户允许 → approve + return true

    /// 契约 M5 / 场景 5.P2（无依赖首次信任）：首次（!trusted）+ 无缺失 → 弹纯信任框，
    /// 用户允许 → approve 写记录 + return true。
    ///
    /// 对应 P#：场景 5.P2（简洁框确认信任 → 直接执行 + trust.json 写入）。
    /// 本测试用 mock TrustPrompt（用户点允许）。
    func test_M5_firstRunNoDeps_userApproves_approvesAndReturnsTrue() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeNoDepsManifest(name: "first-trust-plugin")

        XCTAssertFalse(store.isEverTrusted("first-trust-plugin"), "approve 前应未信任")

        // 注入 mock：missingProvider 返空（无缺失），prompter 用户点「允许」
        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [] },
            prompter: { _, _, _, _, _ in true } // 用户允许
        )

        XCTAssertTrue(allowed, "首次 + 用户允许 → 必须 return true（场景 5.P2）")
        XCTAssertTrue(store.isEverTrusted("first-trust-plugin"),
                      "用户允许后必须 approve 写入信任记录（场景 1.P4 / 5.P2）")
    }

    // MARK: - 场景 1.P1 / 首次信任 + 依赖缺失 + 安装成功 → approve + return true

    /// 契约 M5 / 场景 1：首次（!trusted）+ 有缺失 → 弹合并 TOFU+依赖框，用户点一键安装，
    /// installAll success → approve + return true。
    ///
    /// 对应 P#：场景 1.P1（弹合并框）+ 1.P2（brew install 成功）+ 1.P4（写 trust.json）。
    /// Mutation-Survival：若实现 installAll 失败仍 approve，本测试 mock installer 返 success 仍能过；
    ///   但「installAll failure 不 approve」由下一个测试守护。
    func test_M5_firstRunWithDeps_installSucceeds_approvesAndReturnsTrue() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        let installer = MockInstaller(result: .success)
        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: "二维码生成库",
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { missing in await installer.installAll(missing) },
            prompter: { _, _, _, _, _ in true } // 用户允许
        )

        XCTAssertTrue(allowed,
                      "首次 + 缺失 + 用户允许 + installAll success → 必须 return true（场景 1）")
        XCTAssertTrue(store.isEverTrusted("qr"),
                      "场景 1.P4：installAll success 后必须 approve 写 trust.json")
    }

    // MARK: - 契约-M5: 首次 + 依赖缺失 + 安装失败 → 不 approve + return false

    /// 契约 M5 行为契约：「missing 非空 → DependencyInstaller.installAll → success 才继续」。
    /// 即 installAll 失败 → 不 approve + return false（不执行插件）。
    ///
    /// Mutation-Survival：若实现 installAll 失败仍 approve，本测试挂。
    /// No-op kill：断言 isEverTrusted==false + allowed==false。
    func test_M5_firstRunWithDeps_installFails_doesNotApprove_returnsFalse() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: nil,
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { _ in .partialFailure(["qrencode"]) }, // 安装失败
            prompter: { _, _, _, _, _ in true }
        )

        XCTAssertFalse(allowed,
                       "installAll 失败必须 return false（契约：success 才继续）")
        XCTAssertFalse(store.isEverTrusted("qr"),
                       "installAll 失败时必须不 approve（无信任记录）")
    }

    // MARK: - 场景 1.P1 negate / 首次 + 依赖缺失 + 用户拒绝 → 不 approve + return false

    /// 契约 M5 / 场景 1 negate：用户点「拒绝」→ 不 approve + return false。
    func test_M5_firstRunUserDenies_doesNotApprove_returnsFalse() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: nil,
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { _ in .success }, // 不应被调
            prompter: { _, _, _, _, _ in false } // 用户拒绝
        )

        XCTAssertFalse(allowed, "用户拒绝必须 return false")
        XCTAssertFalse(store.isEverTrusted("qr"), "用户拒绝时必须不 approve")
    }

    // MARK: - 场景 3.P3 / 已信任 + 新增依赖缺失 → 重弹依赖框（不重复信任授权）

    /// 契约 M5 / 场景 3.P3：「When 重弹且已信任，launcher shall 无 TOFU 信任授权动作」。
    /// 「approve 写记录：仅 !trusted；已信任重弹不重复写」。
    ///
    /// 对应 P#：场景 3.P3（重弹 + 已信任 → 无 TOFU 信任授权按钮，仅安装按钮）。
    /// 本测试验证：已信任 + 新增缺失 → 重弹（用户允许 + 安装成功）→ 不重复 approve（信任记录数不增）。
    ///
    /// Mutation-Survival：若实现已信任重弹仍 approve，信任记录会重复，count 断言挂。
    /// No-op kill：断言 approve 前后 trust record count 不变。
    func test_M3_rePromptAlreadyTrusted_doesNotRepeatApprove() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        // 首先建立信任（v1 只有 qrencode 且已装）
        try store.approve(manifest, executablePath: exe)
        let recordCountAfterFirstApprove = try store.list().count
        XCTAssertEqual(recordCountAfterFirstApprove, 1, "首次 approve 后 1 条记录")

        // 场景 3：已信任 + 新增 imagemagick 缺失 → 重弹
        let v2Manifest = makeQRManifestDeps(missingChecks: ["qrencode", "imagemagick"])
        let allowed = await store.checkAndPrompt(
            v2Manifest,
            executablePath: exe,
            missingProvider: { _ in [
                // 仅 imagemagick 缺失（qrencode 已装，collectMissing 过滤）
                DependencyStatus(check: "imagemagick", label: nil,
                                 isInstalled: false, brewPackage: "imagemagick")
            ] },
            installer: { _ in .success },
            prompter: { _, _, _, _, _ in true }
        )

        XCTAssertTrue(allowed, "已信任 + 重弹 + 用户允许 + 安装成功 → return true（场景 3 装后执行）")
        let recordCountAfterRePrompt = try store.list().count
        XCTAssertEqual(recordCountAfterRePrompt, recordCountAfterFirstApprove,
                       "场景 3.P3：已信任重弹不重复 approve（信任记录数不增）")
    }

    // MARK: - 场景 3.P4 negate / 已信任 + 新增依赖 → 重弹时仅装缺失（信任区标记已授权）

    /// 契约 M5 / 场景 3.P4 negate：「仅执行 brew install imagemagick（不重装 qrencode）」。
    /// 本测试验证：重弹时 installAll 收到的 missing 列表仅含缺失的（不含已装的）。
    /// 这由 DependencyResolver.collectMissing 保证（已装的 isInstalled=true 被过滤），
    /// checkAndPrompt 透传 collectMissing 结果给 installAll。
    ///
    /// 对应 P#：场景 3.P4 negate（qrencode 不应重装）。
    /// Mutation-Survival：若 checkAndPrompt 把所有 deps 都传给 installAll（不过滤已装），
    /// MockInstaller 收到的 missing 会含 qrencode，本测试断言挂。
    func test_M3_rePromptAlreadyTrusted_installsOnlyMissing() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])
        try store.approve(manifest, executablePath: exe)

        let v2Manifest = makeQRManifestDeps(missingChecks: ["qrencode", "imagemagick"])
        let installer = MockInstaller(result: .success)

        _ = await store.checkAndPrompt(
            v2Manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "imagemagick", label: nil,
                                 isInstalled: false, brewPackage: "imagemagick")
                // 注意：qrencode 已装不在 missing 里（collectMissing 过滤）
            ] },
            installer: { missing in await installer.installAll(missing) },
            prompter: { _, _, _, _, _ in true }
        )

        // 验证 installAll 收到的 missing 仅含 imagemagick
        let installedChecks = installer.capturedMissing.map(\.check)
        XCTAssertEqual(installedChecks, ["imagemagick"],
                       "场景 3.P4 negate：重弹时仅装 imagemagick，不重装 qrencode")
    }

    // MARK: - 场景 4 / 已信任 + 依赖被卸载 → 重弹

    /// 契约 M5 / 场景 4：已信任插件 + 依赖被卸载（collectMissing 非空）→ 重弹依赖框。
    /// 覆盖「依赖被卸载导致缺失」场景。
    ///
    /// 对应 P#：场景 4.P1（已信任 + 依赖卸载 → 重弹）+ 4.P2（重弹无 TOFU 信任动作）。
    func test_M4_alreadyTrusted_depUninstalled_rePrompts() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        // 建立信任（qrencode 当时已装）
        try store.approve(manifest, executablePath: exe)

        // qrencode 被卸载 → collectMissing 返回 qrencode
        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: nil,
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { _ in .success },
            prompter: { _, _, _, _, _ in true }
        )

        XCTAssertTrue(allowed, "已信任 + 依赖卸载 + 用户允许装回 → return true（场景 4 装后执行）")
        // 4.P2 negate：重弹无 TOFU 信任动作（信任记录不增）
        XCTAssertEqual(try store.list().count, 1,
                       "场景 4.P2 negate：依赖卸载重弹不重复 approve")
    }

    // MARK: - 场景 6 / brew 缺失 + 有 brew 依赖 → checkAndPrompt return false + 引导 brew.sh

    /// 契约 M6 / 场景 6：「collectMissing 非空 + brew missing → checkAndPrompt 返回 false
    /// （点 2 直接失败，弹框引导 brew.sh）」。
    ///
    /// 对应 P#：场景 6.P3 negate（brew 缺失 → 不执行 qr）。
    /// 本测试注入 mock resolver 返回 brewMissing 状态 + mock NSWorkspace 计数，
    /// 验证 checkAndPrompt return false。
    ///
    /// Mutation-Survival：若实现 brew 缺失仍 return true（吞错继续），本测试挂。
    func test_M6_brewMissing_returnsFalse() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        var brewGuideCalled = false
        let allowed = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: nil,
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { _ in
                XCTFail("brew 缺失时不应调 installAll（场景 6）")
                return .success
            },
            prompter: { _, _, _, _, _ in
                XCTFail("brew 缺失应走引导分支，不调标准 prompter")
                return false
            },
            brewAvailability: { .missing }, // brew 缺失
            brewMissingPrompter: { _ in
                brewGuideCalled = true // brew 缺失引导闭包被调
            }
        )

        XCTAssertFalse(allowed,
                       "场景 6.P3 negate：brew 缺失 → checkAndPrompt 必须 return false（不执行 qr）")
        XCTAssertTrue(brewGuideCalled,
                      "场景 6：brew 缺失时 brewMissingPrompter 闭包必须被调（引导分支）")
    }

    // MARK: - 场景 6.P2 OST / brew 缺失 → 引导 NSWorkspace.open("https://brew.sh")
    //
    // VISUAL_RESIDUE: NSWorkspace.open 留 QA 真机判定。
    //   蓝队 TrustPrompt.showBrewMissingGuide 直接调 NSWorkspace.shared.open(URL("https://brew.sh"))
    //   （TrustPrompt.swift:95-96），无 seam 可注入，单测无法 mock 系统单例。
    //   红队原假设的 MockWorkspace.open（计数 + URL 匹配）无法对齐 —— 不强行 mock 系统单例。
    //   间接断言：brewMissingPrompter 闭包被调（证明 brew 缺失引导分支进入，
    //   该分支内部会调 NSWorkspace.open，真机 QA 验证 URL 精确匹配 https://brew.sh）。

    /// 契约 M6 / 场景 6.P2 OST：「用户点「打开 brew.sh」→ NSWorkspace.open("https://brew.sh")」
    /// 点击→系统响应 OST（非仅断言按钮存在）。
    ///
    /// 对应 P#：场景 6.P2（点击 → NSWorkspace.open 调用计数 +1，URL == https://brew.sh）。
    ///
    /// 单测层间接断言：brewMissingPrompter 闭包被调（证明进入 brew 缺失引导分支）。
    ///   NSWorkspace.shared.open 的精确调用 + URL == "https://brew.sh" 留 QA 真机 E2E
    ///   （VISUAL_RESIDUE：蓝队无 NSWorkspace seam，单测无法 mock 系统单例）。
    func test_M6_brewMissing_opensBrewShURL() async throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeQRManifestDeps(missingChecks: ["qrencode"])

        var brewGuideCalled = false
        var capturedMissingForGuide: [DependencyStatus] = []
        _ = await store.checkAndPrompt(
            manifest,
            executablePath: exe,
            missingProvider: { _ in [
                DependencyStatus(check: "qrencode", label: nil,
                                 isInstalled: false, brewPackage: "qrencode")
            ] },
            installer: { _ in
                XCTFail("brew 缺失时不应调 installAll")
                return .success
            },
            prompter: { _, _, _, _, _ in
                XCTFail("brew 缺失应走引导分支")
                return false
            },
            brewAvailability: { .missing },
            brewMissingPrompter: { missing in
                brewGuideCalled = true
                capturedMissingForGuide = missing
            }
        )

        // 间接断言：brewMissingPrompter 闭包被调（证明进入 brew 缺失引导分支）
        XCTAssertTrue(brewGuideCalled,
                      "场景 6.P2 OST 间接断言：brew 缺失时 brewMissingPrompter 闭包必须被调（引导分支进入）")
        // 闭包收到的 missing 含 qrencode（供引导框展示依赖名）
        XCTAssertTrue(capturedMissingForGuide.contains { $0.check == "qrencode" },
                      "brewMissingPrompter 收到的 missing 必须含 qrencode（供引导框展示）")
        // VISUAL_RESIDUE: NSWorkspace.open("https://brew.sh") 的精确调用 + URL 匹配留 QA 真机判定
        // （蓝队 TrustPrompt.showBrewMissingGuide 直接调 NSWorkspace.shared.open，单测无法 mock 系统单例）
    }
}

// MARK: - 横切谓词：REAL_SCENARIO 留 QA 真机判定（红队铁律：visual-residue 标记）
//
// 以下横切 / OST 谓词不在本单测覆盖范围，留 QA Tier 1.5 真机 E2E：
//
// - 场景 1.P2b [det-machine] OST（进度窗「安装中」状态迁移⚡→⟳→✓）：
//   observe: 进度窗 AX 文本 + 状态 badge。
//   单测层已验证 progressPhase 非空（见 DependencyInstallerAcceptanceTests），
//   真实进度窗 AX 可达性 + 文本「安装中」留 QA。
//   // VISUAL_RESIDUE: 留 QA 真机判定（进度窗 AX 文本 + badge 状态迁移）
//
// - 场景 7.P1b [det-machine] OST（点击复制 → NSPasteboard.general 写入）：
//   observe: pasteboard.changeCount +1 + stringRepresentation == "brew install qrencode"。
//   单测层验证了开关 OFF → manualRequired（installAll 不起子进程），
//   真实 NSPasteboard 写入 + changeCount 单调 +1 留 QA（需 NSPanel UI 点击）。
//   // VISUAL_RESIDUE: 留 QA 真机判定（点击复制 → pasteboard.changeCount+1 + 内容匹配）
//
// - Cross.Freshness1 [det-machine]（依赖区 AXGroup + 来源标签 Homebrew）：
//   observe: AX 弹框内依赖区 AXGroup + 来源标签。
//   单测层验证了 DependencyStatus 数据结构（含 brewPackage 来源），
//   真实 NSAlert + SwiftUI accessoryView 的 AX 树断言留 QA。
//   // VISUAL_RESIDUE: 留 QA 真机判定（依赖区 AXGroup + Homebrew 来源标签 AX 可达）
//
// - Cross.Freshness2 [visual-residue]（三层结构：插件信息区/依赖列表区/操作按钮区）：
//   observe: 弹框截图二值清单。
//   // VISUAL_RESIDUE: 留 QA 真机判定（禁 golden-image，走 AX 树 + 二值清单）

// MARK: - Mock seam 类型（已对齐蓝队闭包 seam，CONTRACT_AMBIGUOUS 已解）

/// Mock DependencyInstaller，记录收到的 missing 列表 + 返回预设 InstallResult。
/// 用于场景 3.P4（重弹仅装缺失）：闭包 seam 内包装此 mock，验证 capturedMissing。
private final class MockInstaller {
    let result: InstallResult
    private(set) var capturedMissing: [DependencyStatus] = []

    init(result: InstallResult) {
        self.result = result
    }

    func installAll(_ missing: [DependencyStatus]) async -> InstallResult {
        capturedMissing = missing
        return result
    }
}

// 注：红队原假设的 MockResolver / MockTrustPrompt / MockWorkspace 已移除。
// 蓝队 checkAndPrompt 用 5 闭包 seam（missingProvider/installer/prompter/brewAvailability/brewMissingPrompter），
// 测试直接用闭包字面量适配（如 { _ in missing } / { _,_,_,_,_ in true }），无需独立 Mock 类型。
// NSWorkspace.open（MockWorkspace）因蓝队无 seam，单测无法 mock 系统单例，场景 6.P2 OST 标 VISUAL_RESIDUE 留 QA。
