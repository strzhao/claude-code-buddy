# 005-routing handoff

## 实现摘要

task 005 完成智能路由：LauncherRouter（keyword 缩候选 + AI 选 1 + hallucinate 兜底）+ PluginManifest.toAgentTool() 转换 + LauncherCandidateView 候选 UI + LauncherManager.submit 接入 Router（替换 task 003 echo tool stub）。825 测试全绿，QA Ready to merge: Yes（qa-reviewer Agent 撞 session limit 降级，编排器自审 Section A spot checks 全过）。

## 关键文件路径

```
apps/desktop/Sources/ClaudeCodeBuddy/Launcher/
├── LauncherRouter.swift            [新] RouteDecision + narrowCandidates + aiSelect
├── LauncherCandidateView.swift     [新] SwiftUI 候选 UI（仅非空显示）
└── Plugin/PluginManifest+AgentTool.swift  [新] extension toAgentTool() 含顶层 type:object
```

修改：
- `LauncherConstants.swift` — +`routerMaxCandidates: Int = 5`
- `LauncherManager.swift` — +`@Published lastRouteCandidates/lastRouteSelectedIndex` + submit 替换 echo stub 为 Router 决策路径（保留 task 003 Task.detached + do/catch + continuation.finish 结构）
- `LauncherInputView.swift` — 嵌入 LauncherCandidateView（条件渲染：仅当 lastRouteCandidates 非空显示）
- `apps/desktop/CLAUDE.md` — Launcher 子条目 +`LauncherRouter` + `LauncherCandidateView`

## 下游须知

### Task 006 (Install + TOFU) 接入

**关键接入点**：`LauncherManager.submit` 的 `case .withPlugin(let manifest):` 分支内 `toolExecutor` 闭包（约 LauncherManager.swift:185 附近）。task 005 在此**仅留注释占位**：
```swift
// ⚠️ task 005 范围明确不含 trust check。task 006 将在**此行**插入：
//   TrustStore.shared.check(manifest) — 未信任时弹 NSAlert + 抛 pluginNotTrusted
```

task 006 实现路径：
1. `LauncherError.swift` 同文件追加 `case pluginNotTrusted(String)` + errorDescription
2. 新建 `Launcher/Plugin/TrustStore.swift`（singleton + isTrusted/approve/remove + TOFU NSAlert + ~/.buddy/launcher-trust.json）
3. 在 toolExecutor 闭包 `guard name == manifest.name` 之后插入 trust check
4. `Sources/BuddyCLI/main.swift` 内联 `buddy launcher add/list/remove/inspect` 子命令（避免 BuddyCore 依赖，参考 task 002 launcher config 模式）

### Task 007 (E2E + Docs) 接入

LauncherInputView 已嵌入 CandidateView。task 007 可加视觉/集成测试验证完整路由 → 执行链路。

## 设计偏差（蓝队 2 项已确认合理）

1. **narrowCandidates 加反向 contains 检查**：除"token 在 haystack 中"正向，加"keyword 是否被 query 包含"反向（`queryLower.contains(kw)`）。设计未明确，但解决中文场景必要——中文 query "请翻译这段：Hello" 不易分词，整段 token 反包含 keyword "翻译" 才能命中。场景 9 因此通过。
2. **@Published 通过 LauncherManager.shared 单例引用**：而非 weak self（Swift 并发隔离规则下 detached task 内访问 self.@Published 受限）。

## 已知 backlog

1. **[Important]** qa-reviewer Agent 撞 session limit — 后续大改动建议拆分（task 002/003/004 蓝队也撞过）
2. **[Important]** v2+ 增强：LauncherProvider.send 协议加 `system: String?` 参数，避免 router prompt 拼 user message 前缀
3. **[Minor]** v2+ 增强：候选 UI 加上下箭头切换 + ProviderConfig.routerModel 独立字段
4. **[Inherited]** task 002 make bundle 未更新 .app 内 CLI（task 008 修复）
5. **[Inherited]** task 003 LauncherInputView.onDisappear 持 Task handle 真正 cancel（task 007）
6. **[Inherited]** task 004 PluginExecutor 系列：kill(-pid) 默认 pgid 无效 / init 私有 / readBounded alreadyResumed 局部 / 注释 sleep 10 同步等

## 验证证据

- `swift test --filter Launcher` → 167 tests / 0 failed
- `swift test` 全套 → 825 tests / 0 failed
- `make lint` → 0 violations in 95 files
- `make build && make bundle` → 通过
- contract-checker → 0 mismatches
- Wave 1.5 9/9 真实场景（38 acceptance tests + 7 测试类）：narrowCandidates 评分 / 空 / 不匹配 / AI 选中 / AI NONE / AI hallucinate 兜底 / toAgentTool 契约 / submit 集成 / 中文 query

## 下游接入点示例（task 006 trust check 插入）

```swift
// LauncherManager.swift submit 内 toolExecutor 闭包：
toolExecutor = { name, input in
    guard name == manifest.name else { throw LauncherError.pluginNotFound(name) }
    // task 006 新增（task 005 注释占位）：
    guard TrustStore.shared.isTrusted(manifest) else {
        let approved = await TrustStore.shared.askUser(plugin: manifest)
        guard approved else { throw LauncherError.pluginNotTrusted(manifest.name) }
        try TrustStore.shared.approve(manifest)
    }
    // 继续原 PluginExecutor.shared.execute(...)
}
```
