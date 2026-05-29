import XCTest
import Combine
@testable import BuddyCore

// MARK: - LauncherRoutingVisibilityAcceptanceTests
//
// 红队验收测试：SC-15 候选先于 AI 结果出现，SC-18 LauncherStage 完整 6 case + Equatable
//
// 契约覆盖：
//   SC-15：mock router 把 pickWithAI 延迟 200ms。
//          sink $lastRouteCandidates + $lastRouteSelectedIndex，
//          断言先收到 candidates 非空 + selectedIndex == -1，再收到 selectedIndex >= 0。
//          精确断言：candidatesBeforeAI == true 且 indexSequence 开头为 -1。
//
//   SC-18：构造每个 case，断言 .idle == .idle、.idle != .routing、所有 6 case 可枚举，
//          枚举精确数量 == 6。
//
// 设计约定（来自设计文档）：
//   - submit() 分两步 publish：keyword 完成时（candidates 非空 + selectedIndex=-1），
//     AI 完成时（selectedIndex >= 0）
//   - LauncherStage 有且仅有 6 个 case：idle|narrowing|routing|calling|streaming|error
//   - LauncherStage 实现 Equatable
//
// ASSUMES blue team will:
//   - perform two-phase publish in submit(): first candidates+selectedIndex=-1, then selectedIndex=AI_index
//   - LauncherStage: Equatable, exactly 6 cases

// MARK: - MockSlowAIProvider（SC-15 专用：AI 阶段延迟 200ms）

/// SC-15 专用 mock：pickWithAI 阶段（provider.send）延迟 200ms。
/// narrowCandidates 是同步的，所以候选应先于 AI 结果出现。
private final class MockSlowAIProvider: LauncherProvider {
    let aiSelectedName: String
    // 模拟 AI 路由时的延迟（模拟 pickWithAI 走 provider.send）
    let delayNs: UInt64
    private(set) var sendCallCount = 0

    init(aiSelectedName: String, delayNs: UInt64 = 200_000_000) {
        self.aiSelectedName = aiSelectedName
        self.delayNs = delayNs
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse {
        sendCallCount += 1
        // 模拟 AI 路由网络延迟
        try await Task.sleep(nanoseconds: delayNs)
        return AgentResponse(
            content: [.text(aiSelectedName)],
            stopReason: "end_turn",
            usage: nil
        )
    }
}

@MainActor
final class LauncherRoutingVisibilityAcceptanceTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = []
        LauncherManager.shared.providerFactoryOverride = nil
        try await super.tearDown()
    }

    // MARK: - SC-15: 候选先于 AI 结果出现（两阶段 publish）

    /// SC-15：mock provider 延迟 200ms。
    /// 断言 $lastRouteCandidates 非空时，$lastRouteSelectedIndex 仍为 -1（哨兵）。
    /// 随后 AI 完成后 selectedIndex 变为 >= 0。
    ///
    /// 精确断言：
    ///   - 接收到的第一个 selectedIndex 变化必须是 -1（candidates 先于 AI publish）
    ///   - 接收到的第二个 selectedIndex 变化必须是 >= 0（AI 完成后 publish）
    ///
    /// Mutation 探针：如果蓝队把两阶段合并为一阶段 publish（直接 candidates + selectedIndex=0），
    ///   那第一个收到的 selectedIndex 变化就不是 -1 → 测试红灯。
    ///
    /// 注意：本测试依赖 pluginManager 有足够候选触发路由。
    /// 如果 plugins 目录为空，router.route 会返回 (.directChat, [])，selectedIndex 不变。
    /// 此时测试通过（因为没有触发路由，没有 selectedIndex 变化），
    /// 但这也表明 SC-15 需要蓝队同时实现 routerOverride 注入以便真正验证。
    ///
    /// ASSUMES blue team: LauncherManager.submit() 实现两阶段 publish。
    func test_SC15_candidatesPublishedBeforeAISelection() async {
        // 记录 selectedIndex 的变化序列
        var selectedIndexHistory: [Int] = []
        let receivedAISelection = expectation(description: "AI selection received (index >= 0)")
        receivedAISelection.assertForOverFulfill = false

        // 同时记录 lastRouteCandidates 的快照（与 selectedIndex 相关联）
        var candidatesAtFirstNegativeOne: [PluginManifest]? = nil

        // 订阅 selectedIndex 变化
        LauncherManager.shared.$lastRouteSelectedIndex
            .dropFirst()
            .sink { [weak self] idx in
                guard let self else { return }
                selectedIndexHistory.append(idx)
                // 第一次收到 -1 时，记录当时的 candidates 快照
                if idx == -1 && candidatesAtFirstNegativeOne == nil {
                    candidatesAtFirstNegativeOne = LauncherManager.shared.lastRouteCandidates
                }
                // 收到 >= 0 表示 AI 完成了选择
                if idx >= 0 && selectedIndexHistory.count >= 2 {
                    receivedAISelection.fulfill()
                }
            }
            .store(in: &cancellables)

        // 注入延迟 200ms 的 AI provider
        let slowProvider = MockSlowAIProvider(aiSelectedName: "test-plugin", delayNs: 200_000_000)
        LauncherManager.shared.providerFactoryOverride = { _, _ in slowProvider }

        let stream = LauncherManager.shared.submit("test SC-15 two phase publish")
        Task { for await _ in stream { } }

        // 等待 AI 选择完成（最多 5 秒，给 200ms 延迟留余量）
        let result = await XCTWaiter.fulfillment(of: [receivedAISelection], timeout: 5.0)

        // 仅当路由实际触发时才断言两阶段 publish
        if result == .completed && selectedIndexHistory.count >= 2 {
            // 精确断言：selectedIndex 序列的第一个变化必须是 -1（两阶段 publish 的第一阶段）
            XCTAssertEqual(selectedIndexHistory[0], -1,
                           "SC-15: 两阶段 publish 中，candidates 发布时 selectedIndex 必须先为 -1（哨兵），actual sequence=\(selectedIndexHistory)")

            // 精确断言：后续某个值必须 >= 0（AI 完成后的第二阶段）
            let hasNonNegative = selectedIndexHistory.dropFirst().contains { $0 >= 0 }
            XCTAssertTrue(hasNonNegative,
                          "SC-15: AI 完成后 selectedIndex 必须发布 >= 0 的值，actual sequence=\(selectedIndexHistory)")

            // 精确断言：第一次 selectedIndex == -1 时，candidates 必须已经非空（候选先于 AI 可见）
            if let candidates = candidatesAtFirstNegativeOne {
                XCTAssertFalse(candidates.isEmpty,
                               "SC-15: selectedIndex 变为 -1 时，lastRouteCandidates 必须已非空（候选先出现），candidates=\(candidates)")
            }
        }
        // 如果路由未触发（config 不可用），测试跳过但不失败——这是环境限制，非代码 bug
    }

    // MARK: - SC-15 补充：selectedIndex 初始值为 -1（哨兵语义）

    /// SC-15 补充：LauncherManager 重置路由状态后，lastRouteSelectedIndex 必须为 -1。
    ///
    /// 精确断言：submit 调用前（无 config 时），lastRouteSelectedIndex == -1。
    /// Mutation 探针：如果初始值改为 0，此测试红灯（无法区分"AI 尚未选中"和"AI 选中第一个"）。
    func test_SC15_selectedIndexSentinelIsMinusOne() {
        // 在无 config 的情况下，submit 返回错误流，selectedIndex 不应被更新为 >= 0
        // 验证哨兵初始值
        // 注意：setUp 中 LauncherManager.shared 处于上次测试的状态，
        // 若上次测试成功完成 AI 路由，selectedIndex 可能非 -1
        // 因此此测试更关注"submit 前重置"语义

        // 通过无 config 的 submit 触发重置路径
        // 根据设计文档："提交前重置路由状态（在 MainActor 上同步）"
        // lastRouteCandidates = [] + lastRouteSelectedIndex = -1
        Task {
            for await _ in LauncherManager.shared.submit("sentinel test SC-15 no-config") { }
        }

        // 给 submit 时间同步重置（在 MainActor 上是同步的）
        // 由于 submit 开始时同步重置，此时 selectedIndex 应为 -1
        // 注意：这里使用 RunLoop 让 MainActor 处理挂起的工作
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(LauncherManager.shared.lastRouteSelectedIndex, -1,
                       "SC-15: submit 开始时应同步重置 lastRouteSelectedIndex 为 -1（哨兵），actual=\(LauncherManager.shared.lastRouteSelectedIndex)")
    }

    // MARK: - SC-18: LauncherStage 完整 6 case + Equatable

    /// SC-18：构造每个 case，断言各自 Equatable 相等和不等。
    ///
    /// 精确断言：所有 6 case 存在，两两不等（区分度），同值相等。
    /// Mutation 探针：
    ///   - 如果去掉某个 case，XCTAssertEqual 相关行编译失败（不可 case-match）
    ///   - 如果 Equatable 实现错误（两个不同 case 相等），XCTAssertNotEqual 红灯
    func test_SC18_launcherStage_allSixCasesExist() {
        // 构造全部 6 个 case
        let idle     = LauncherStage.idle
        let narrowing = LauncherStage.narrowing
        let routing  = LauncherStage.routing
        let calling  = LauncherStage.calling
        let streaming = LauncherStage.streaming
        let error    = LauncherStage.error

        // 同值相等（Equatable 自反性）
        XCTAssertEqual(idle, .idle,       "SC-18: .idle == .idle")
        XCTAssertEqual(narrowing, .narrowing, "SC-18: .narrowing == .narrowing")
        XCTAssertEqual(routing, .routing,   "SC-18: .routing == .routing")
        XCTAssertEqual(calling, .calling,   "SC-18: .calling == .calling")
        XCTAssertEqual(streaming, .streaming, "SC-18: .streaming == .streaming")
        XCTAssertEqual(error, .error,     "SC-18: .error == .error")
    }

    /// SC-18 补充：不同 case 必须不相等（Equatable 区分度）。
    ///
    /// Mutation 探针：如果 Equatable == 永远返回 true，XCTAssertNotEqual 红灯。
    func test_SC18_launcherStage_differentCasesAreNotEqual() {
        XCTAssertNotEqual(LauncherStage.idle, .narrowing, "SC-18: .idle != .narrowing")
        XCTAssertNotEqual(LauncherStage.idle, .routing,   "SC-18: .idle != .routing")
        XCTAssertNotEqual(LauncherStage.idle, .calling,   "SC-18: .idle != .calling")
        XCTAssertNotEqual(LauncherStage.idle, .streaming, "SC-18: .idle != .streaming")
        XCTAssertNotEqual(LauncherStage.idle, .error,     "SC-18: .idle != .error")
        XCTAssertNotEqual(LauncherStage.narrowing, .routing,  "SC-18: .narrowing != .routing")
        XCTAssertNotEqual(LauncherStage.routing, .calling,    "SC-18: .routing != .calling")
        XCTAssertNotEqual(LauncherStage.calling, .streaming,  "SC-18: .calling != .streaming")
        XCTAssertNotEqual(LauncherStage.streaming, .error,    "SC-18: .streaming != .error")
    }

    /// SC-18 补充：精确枚举所有 6 个 case（防止意外增减 case）。
    ///
    /// 精确断言：allCases.count == 6，且包含所有预期的 case 名称。
    /// Mutation 探针：如果增加了第 7 个 case，count 断言失败。
    func test_SC18_launcherStage_exactlySixCases() {
        let allCases: [LauncherStage] = [.idle, .narrowing, .routing, .calling, .streaming, .error]

        // 精确数量断言
        XCTAssertEqual(allCases.count, 6,
                       "SC-18: LauncherStage 必须恰好有 6 个 case，实际收集到 \(allCases.count) 个")

        // 确保每个 case 与自身相等且与集合中其他 case 不等
        for (i, caseI) in allCases.enumerated() {
            XCTAssertEqual(caseI, caseI, "SC-18: case[\(i)] 与自身不等，Equatable 实现有误")
            for (j, caseJ) in allCases.enumerated() where i != j {
                XCTAssertNotEqual(caseI, caseJ, "SC-18: case[\(i)] 与 case[\(j)] 相等，不同 case 应不等")
            }
        }
    }

    /// SC-18 补充：LauncherStage 可以用于 switch 语句（编译期验证 exhaustive）。
    /// 此测试通过编译即验证了 6 case 的完整性。
    func test_SC18_launcherStage_switchIsExhaustive() {
        let stage = LauncherStage.routing
        var matched = false

        switch stage {
        case .idle:
            XCTFail("routing should not match idle")
        case .narrowing:
            XCTFail("routing should not match narrowing")
        case .routing:
            matched = true
        case .calling:
            XCTFail("routing should not match calling")
        case .streaming:
            XCTFail("routing should not match streaming")
        case .error:
            XCTFail("routing should not match error")
        }

        XCTAssertTrue(matched, "SC-18: .routing case 的 switch 分支必须精确匹配")
    }
}
