---
id: "007-e2e-and-docs"
depends_on: ["005-routing", "006-install-and-tofu"]
complexity: S
milestone: M5
acceptance_scenarios: [SC-10, SC-11, all]
contract_required: false
---

# 007 — 端到端验收 + Snapshot 测试 + 文档

## 目标

跑全部 12 个验收场景的端到端测试（含 LauncherIsolationTests 验证与像素猫互不干扰），补完 CLAUDE.md 文档，发布前确认。本任务**只**做测试+文档+小调整，不引入新功能。

## 架构上下文

- 文件落点：
  - `apps/desktop/tests/BuddyCoreTests/Launcher/LauncherE2ETests.swift`
  - `apps/desktop/tests/BuddyCoreTests/Launcher/LauncherIsolationTests.swift`
  - `apps/desktop/tests/BuddyCoreTests/Launcher/LauncherSnapshotTests.swift`
  - `apps/desktop/CLAUDE.md` 更新（新增 Launcher 子系统章节）
  - `CLAUDE.md`（根级，简短链接到 desktop CLAUDE.md）

## 输入

- 所有前置任务的 handoff（001-006）
- 12 个验收场景列表（见状态文件 `## 验收场景`）

## 输出契约

### 测试套件结构

```swift
// LauncherE2ETests.swift（场景级，每个测试方法对应 1 个 SC）
final class LauncherE2ETests: XCTestCase {
    func test_SC01_召唤与隐藏() async throws { ... }
    func test_SC02_BYOK配置持久化() async throws { ... }
    func test_SC03_直接对话流式渲染() async throws { ... }
    func test_SC04_插件安装与TOFU弹框() async throws { ... }
    func test_SC05_TOFU允许后执行() async throws { ... }
    func test_SC06_TOFU拒绝() async throws { ... }
    func test_SC07_未配置provider错误() async throws { ... }
    func test_SC08_每次唤起新session() async throws { ... }
    func test_SC09_remove卸载() async throws { ... }
    func test_SC11_inspect查看详情() async throws { ... }
    func test_SC12_Ollama配置与失联() async throws { ... }
    // SC-10 单独在 LauncherIsolationTests
}

// LauncherIsolationTests.swift（专门验证与像素猫不干扰）
final class LauncherIsolationTests: XCTestCase {
    func test_SC10_召唤期间BuddyScene状态不变() async throws {
        // 1. 启动 buddy app（含像素猫）
        // 2. 让 CatSprite 进入 idle 状态
        // 3. 召唤 launcher，发一次对话
        // 4. 断言 BuddyScene.cat.stateMachine.currentState == idle 不变
        // 5. 断言 SocketServer 收到的 hook message 数量不变
        // 6. 关闭 launcher
        // 7. 再次断言 cat 状态不变
    }
    
    func test_启动器关闭不影响SessionManager() async throws { ... }
}

// LauncherSnapshotTests.swift（视觉回归）
final class LauncherSnapshotTests: XCTestCase {
    func test_LauncherWindow_空状态() { ... }
    func test_LauncherWindow_输入态() { ... }
    func test_LauncherWindow_输出态markdown() { ... }
    func test_LauncherCandidateView_5候选() { ... }
    func test_LauncherCandidateView_无候选() { ... }
}
```

### CLAUDE.md 增量（apps/desktop/CLAUDE.md）

新增章节模板：

```markdown
## Launcher 子系统

Alfred 式 AI 启动器：⌘⇧Space 召唤浮窗 + AI 路由 + CLI 插件生态。

### 架构
- `Sources/ClaudeCodeBuddy/Launcher/` — 全部启动器代码
- 与像素猫互不干扰（独立 NSPanel + 独立配置目录 ~/.buddy/）
- AppDelegate.applicationDidFinishLaunching 末尾 `setupLauncher()` 单点接入

### 用户配置
- `buddy launcher config set --provider anthropic --kind anthropic --model claude-sonnet-4-5 --api-key sk-ant-...`
- `buddy launcher config set --provider ollama --kind openai-compatible --base-url http://localhost:11434/v1 --model qwen2.5:7b --api-key dummy`
- `buddy launcher config use ollama`
- 配置文件 `~/.buddy/launcher.json`
- API key 在 Keychain（生产）或 `~/.buddy/launcher-secrets.enc`（ad-hoc 签名降级）

### 插件管理
- `buddy launcher add <user>/<repo>` — 从 GitHub 装插件
- `buddy launcher list` — 列出已装
- `buddy launcher inspect <name>` — 查看详情（JSON）
- `buddy launcher remove <name>` — 卸载
- 首次执行有 TOFU NSAlert 确认

### 编写插件
plugin.json 字段：name/version/description/keywords/cmd/args/env/timeout/requiredPath
stdin = JSON `{query, sessionId, cwd}`；stdout = markdown；超时 ≤ 30s
```

### 接口签名（example）

```
# E2E 测试运行
Given: swift test --filter LauncherE2ETests
When:  执行所有 SC 测试
Then:  全部 PASS

# Snapshot 测试运行
Given: 已有 __Snapshots__/ 基线
When:  swift test --filter LauncherSnapshotTests
Then:  全部 PASS（无视觉回归）

# 首次运行 Snapshot（无基线）
Given: __Snapshots__/Launcher/ 不存在
When:  swift test --filter LauncherSnapshotTests
Then:  生成基线，测试 FAIL 一次（约定，需 commit 后再跑）
```

### 边界值（DbC）

- E2E 测试单个超时：≤ 60s
- 全套测试总耗时：≤ 5min
- Snapshot 精度：默认 1.0（除非 SwiftUI 渲染有抖动，可降到 0.95）

### 错误契约

N/A — 测试任务无运行时错误码。

### 副作用清单

- 测试运行时：创建临时 `~/.buddy-test/`（不污染真实 `~/.buddy/`），结束后清理
- Snapshot 生成在 `__Snapshots__/Launcher/`
- CLAUDE.md 文件追加

## 验收标准

- ✅ 全部 12 个验收场景的 E2E 测试 PASS
- ✅ SC-10 LauncherIsolationTests 独立验证不干扰像素猫
- ✅ SC-11 inspect 输出 JSON 通过 schema 校验（含所有 5 个字段）
- ✅ Snapshot 测试基线已 commit，CI 跑过
- ✅ `apps/desktop/CLAUDE.md` 含 Launcher 子系统章节，根 CLAUDE.md 加链接
- ✅ `make -C apps/desktop test` 全部通过
- ✅ `make -C apps/desktop lint` 0 警告

## 测试要求

本任务**就是**测试任务。要求：
- E2E 测试用真实的 LauncherManager / Router / Agent / PluginManager（不 mock 核心组件）
- Provider 用 URLProtocol mock（不打真实 API）
- Plugin 子进程用 bundled HelloPlugin 和测试 fixture plugin（在 tests/Resources/）
- LauncherIsolationTests 启动完整 buddy app（含 SessionManager + BuddyScene）

## 风险与缓解

- **测试间状态污染**：每个 E2E 测试用独立的 testHome 目录（`tearDown` 删除）
- **Snapshot 在 CI 上字体抖动**：固定字体 + 降精度到 0.95；首次生成基线后手动 review
- **LauncherIsolationTests 启动完整 app 慢**：用 @MainActor + minimum buddy app config（不启动 SocketServer 监听真实路径）
- **CI 上 Ollama 不可用**：SC-12 标记 `XCTSkip` 当本地无 ollama 时；用 mock 模拟 ollama 协议

## 接出

handoff 写：测试覆盖率报告 + 任何 known issues（如 SC-10 是否需要重构 BuddyScene 才能可测）+ release-ready checklist。
