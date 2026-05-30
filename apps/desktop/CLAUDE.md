# Claude Code Buddy — Desktop App

macOS 桌面应用：Dock 上方的像素猫咪，实时反映 Claude Code 工作状态。

## 架构

```
Sources/
├── BuddyCLI/           # CLI 工具: buddy 命令行
├── ClaudeCodeBuddy/    # App 源码目录（BuddyCore library）
│   ├── App/            # AppDelegate, main.swift 入口
│   ├── Entity/         # 实体抽象层
│   │   ├── EntityProtocol.swift  # 实体协议接口
│   │   ├── EntityState.swift     # 通用状态枚举（跨层使用）
│   │   ├── Cat/            # 猫实体
│   │   │   ├── CatSprite.swift   # 猫精灵（~350 行，组装组件）
│   │   │   ├── CatConstants.swift # 所有猫相关常量
│   │   │   └── States/     # GKState 子类（5 个状态 + ResumableState）
│   │   └── Components/     # 可复用组件
│   │       ├── AnimationComponent.swift
│   │       ├── MovementComponent.swift
│   │       ├── JumpComponent.swift
│   │       ├── InteractionComponent.swift
│   │       └── LabelComponent.swift
│   ├── Environment/    # 环境/天气系统
│   │   ├── EnvironmentResponder.swift
│   │   ├── BehaviorModifier.swift
│   │   └── SceneEnvironment.swift
│   ├── Event/          # Combine 事件总线
│   │   ├── EventBus.swift
│   │   └── BuddyEvent.swift
│   ├── Scene/          # SpriteKit 场景: BuddyScene, FoodManager, TooltipNode
│   ├── Session/        # 会话管理: SessionManager, SessionInfo, SessionColor
│   ├── Network/        # IPC: SocketServer (Unix domain socket), HookMessage
│   ├── Terminal/       # 终端适配: GhosttyAdapter (AppleScript 控制)
│   ├── Launcher/       # Alfred 式 AI 启动器: LauncherManager(AsyncStream submit), LauncherWindow, LauncherInputView
│   │   ├── Provider/   # LauncherProvider 协议 + AnthropicProvider + OpenAICompatibleProvider + ProviderFactory
│   │   ├── Config/     # SecretStore(Keychain→EncryptedFile 探针降级) + LauncherConfig JSON
│   │   ├── Agent/      # LauncherAgent(永远 loop+tool_use 早停) + AgentEvent enum + AgentMessage/AgentTool/AnyCodable
│   │   ├── Plugin/     # PluginManager(扫描~/.buddy/launcher-plugins/) + StdinExecutor(Process子进程) + PluginDispatcher(mode分发) + PluginManifest(Codable schema)
│   │   │               # + PluginManifest+AgentTool.swift (toAgentTool() extension，inputSchema 含顶层 type:object)
│   │   ├── LauncherRouter.swift          # keyword 缩候选(routerMaxCandidates=5) + aiSelect 选 1 → RouteDecision
│   │   ├── LauncherCandidateView.swift   # SwiftUI 候选列表展示（嵌入 LauncherInputView）
│   │   └── Builtin/                      # 内置插件体系（task 011）
│   │       ├── BuiltinPlugin.swift        # 协议：id/priority/sectionTitle/actions(for:) async
│   │       ├── BuiltinPluginRegistry.swift # 仲裁：fan-out 并发 + 跨插件归并 + score 降序 + 截断
│   │       ├── LauncherAction.swift       # 动作值类型：id/title/subtitle/icon/score/perform
│   │       └── AppLauncher/              # 首个内置插件：搜索打开 App
│   │           ├── AppEntry.swift         # 纯值 Sendable：url/name/nameLower/aliases（多别名索引）
│   │           ├── AppIndex.swift         # @MainActor 内存索引：TTL 扫盘 + 注入构造器
│   │           ├── AppMatcher.swift       # 纯函数打分：前缀(1000)>词首(500)>子序列(100)
│   │           ├── AppLaunching.swift     # seam 协议：生产 NSWorkspace / 测试 Mock
│   │           └── AppLauncherPlugin.swift # BuiltinPlugin 实现：接 Index+Matcher → LauncherAction
│   ├── Window/         # 窗口: BuddyWindow, DockTracker, MouseTracker
│   ├── MenuBar/        # 状态栏弹窗: SessionPopoverController
│   ├── Assets/Sprites/ # 48x48 像素猫咪精灵图
│   └── Resources/      # Info.plist
└── App/                # App 可执行文件入口 (main.swift)
```

**数据流**: Claude Code Hook → buddy-hook.sh → Unix Socket → SocketServer → SessionManager → EventBus → BuddyScene/CatSprite

**猫咪状态机** (GKStateMachine): CatIdleState(sleep/breathe/blink/clean) → CatThinkingState(paw+sway) → CatToolUseState(random walk) → CatPermissionRequestState(alert+badge) → CatEatingState

## Launcher 子系统

Alfred 式 AI 启动器：⌘⇧Space 召唤浮窗 + AI 路由 + CLI 插件。**与像素猫互不干扰**（独立 NSPanel + 独立配置目录 `~/.buddy/` + 静态隔离测试 SC-10）。

**视觉风格（task 010）**: Apple HIG / Raycast 风格。NSVisualEffectView (.menu) + SwiftUI .ultraThinMaterial 双层毛玻璃，16pt 圆角，spring 入场动画，SF Symbol 选中指示器（chevron.right.fill + 左侧 sage Capsule 竖条），全 .rounded 字体规范。

### 内置插件体系（task 011）

**即时候选管线**：输入时 debounce(120ms) 后查询 `BuiltinPluginRegistry`，`instantActions` 非空时优先显示内置候选（Raycast 风行布局），按 Enter 直接执行，无匹配则落回 AI 流。

**BuiltinPlugin 协议** — 所有内置能力统一实现：
- `id`：插件唯一标识
- `priority`：仲裁权重（同 query 多插件并发，按优先级分区）
- `sectionTitle`：候选列表分区标题
- `actions(for:) async -> [LauncherAction]`：返回候选动作列表

**AppLauncherPlugin**（首个内置插件，`priority=0`）：
- 三个扫描目录：`/Applications`、`/System/Applications`、`~/Applications`
- 多别名索引（`AppEntry.aliases`）：索引 `CFBundleDisplayName/CFBundleName/CFBundleIdentifier 成分`，解决「微信」搜 `wechat`、「哔哩哔哩」搜 `bilibili` 搜不到的问题
- `AppMatcher` 打分：前缀(1000) > 词首连续(500) > 子序列(100)，同分按 name 字典序稳定排序
- `AppIndex` TTL=60s 后台重扫，冷启动 fire-and-forget 不阻塞 UI

**3 处交互优化**：
- Emacs 键位：`Ctrl-N` 下 / `Ctrl-P` 上，在候选列表导航
- 选中高亮：纯色 sage pill（light #3a7d68 / dark #52a688，alpha 0.92），无竖条边框
- 中文 App 可用英文名搜索（见上方多别名索引）

### 用户配置

API key 存储：Keychain（生产签名）或 `~/.buddy/launcher-secrets.enc`（ad-hoc 签名时 CryptoKit 加密降级）。配置 `~/.buddy/launcher.json` JSON 明文。

```bash
# Anthropic
buddy launcher config set --provider anthropic --kind anthropic \
  --model claude-sonnet-4-5 --api-key sk-ant-xxx

# 本地 Ollama
buddy launcher config set --provider ollama --kind openai-compatible \
  --base-url http://localhost:11434/v1 --model qwen2.5:7b --api-key dummy

# 切换激活
buddy launcher config use ollama
buddy launcher config get
```

### 插件管理

```bash
buddy launcher add stringzhao/buddy-translate     # git clone --depth 1
buddy launcher list                                # 已装插件 + trust 状态
buddy launcher inspect buddy-translate             # JSON 详情
buddy launcher remove buddy-translate              # 卸载 + 清 trust
```

### TOFU 安全模型

首次执行插件弹 NSAlert 确认。`trustKey = SHA256(cmd + args + sha256(executable bytes))`，任一改动（含二进制内容）使旧信任失效，强制重新弹框。trust 记录：`~/.buddy/launcher-trust.json`（0644）。

### 故障排查

- **快捷键被占用** → `buddy launcher config get` 查看 `hotkey` 字段，或在 LauncherWindow 显示时按 ⌘, 改键
- **trust.json 损坏** → 删除 `~/.buddy/launcher-trust.json`，下次执行重新弹框
- **SecretStore 探针降级** → ad-hoc 签名时自动从 Keychain 降级到 EncryptedFile；查 logs `LauncherSecretStore probe failed`
- **plugin 安装失败 exit 1** → 检查网络 / `git clone` 60s 超时
- **plugin manifest 无效 exit 2** → 查看 `plugin.json` 是否符合 PluginManifest schema（cmd 不含 `..` 或绝对路径）

## 开发

```bash
make build          # 编译 debug
make run            # 编译并启动
make test           # 运行单元测试
make lint           # SwiftLint 检查
make lint-fix       # SwiftLint 自动修复 + 检查
make format         # SwiftFormat 格式化
make clean          # 清理构建产物
make release        # 编译 release
make bundle         # 打包 .app
```

### CLI 工具

`buddy` 命令行工具（安装后位于 `ClaudeCodeBuddy.app/Contents/MacOS/buddy`，Homebrew 自动 symlink 到 `/usr/local/bin/buddy`）用于方便地操作猫咪：

```bash
# 检查 app 是否运行
buddy ping

# 创建调试猫
buddy session start --id debug-A --cwd ~/myproject

# 结束调试猫
buddy session end --id debug-A

# 发送事件
buddy emit thinking --id debug-A
buddy emit tool_start --id debug-A --tool Read --desc "Reading file"
buddy emit tool_end --id debug-A --tool Read

# 设置标签
buddy label debug-A "My Project"

# 查看活跃会话
buddy status

# 自动测试（遍历所有状态）
buddy test --delay 2

# 查询猫咪可视状态（JSON 输出）
buddy inspect --id <session-id>

# 模拟点击猫咪（触发 acknowledgePermission + removePersistentBadge）
buddy click --id <session-id>
```

## 测试

- `swift test` — XCTest 单元测试 (tests/BuddyCoreTests/)
- `swift test --filter Snapshot` — 视觉快照回归测试
- `tests/acceptance/run-all.sh` — Shell 验收测试
- CLI 自动测试: `buddy test --delay 2` — 遍历所有状态
- 手动测试 socket: `echo '{"event":"session_start","session_id":"test","timestamp":0,"cwd":"/tmp"}' | nc -U /tmp/claude-buddy.sock`

### 快照测试 (swift-snapshot-testing)

视觉回归测试位于 `tests/BuddyCoreTests/SnapshotTests/`，基线图存储在 `__Snapshots__/` 子目录（已提交到 git）。

**覆盖范围**:
- `SkinCardSnapshotTests` — 皮肤卡片各状态（选中/未选中/远程/下载中/变体）
- `SkinGallerySnapshotTests` — 皮肤市场整体布局
- `CatSpriteSnapshotTests` — 猫咪 6 种状态（idle/thinking/toolUse/permissionRequest/eating/taskComplete）

**使用规范**:
- 修改 UI 组件后必须运行 `swift test --filter Snapshot` 验证无回归
- 如果 UI 变更是预期的，删除对应 `__Snapshots__/` 下的旧基线图后重新运行测试录制新基线
- 新增 UI 组件时应同步新增快照测试用例
- SpriteKit 测试使用 `precision: 0.90` 容差（GPU 渲染固有微小差异）
- AppKit 测试使用默认精确比对（渲染完全确定性）

**autopilot 集成**: 后续 autopilot QA 阶段应包含 `swift test --filter Snapshot` 作为验证步骤之一。

### QA 验证优先级

AI 在 QA 阶段验证 SpriteKit 可视状态时，按以下优先级自主验证，**不要依赖用户手动截图或目视确认**：

1. **首选 `buddy inspect --id <session>`** — 返回机器可读 JSON，可直接断言 state、label_text、tab_name、has_alert_overlay、has_persistent_badge、permission_acknowledged 等字段
2. **次选 `buddy click --id <session>`** — 模拟用户点击，触发交互逻辑后立即 inspect 验证副作用
3. **兜底：人工确认** — 仅当 inspect 无法覆盖的纯视觉效果（动画帧率、颜色渐变、像素对齐）时才使用 AskUserQuestion

### QA E2E 验证流程

QA 阶段不能只跑单元测试就写结论，必须启动真实 app 做端到端验证：

1. `make build && make bundle` — 构建新版本
2. 关闭旧 app → `open ../../ClaudeCodeBuddy.app` 启动新版本（或直接 `make run`）
3. 按验证方案用 `buddy` CLI（session start → emit → inspect）逐场景执行
4. `buddy inspect --id <session>` 的 JSON 输出作为证据写入 QA 报告
5. 验证完毕后 `buddy session end` 清理调试猫

## Package 结构

- `BuddyCore` (library target) — 所有业务逻辑（位于 Sources/ClaudeCodeBuddy/）
- `ClaudeCodeBuddy` (executable target) — App 入口（仅 main.swift）
- `buddy-cli` (executable target) — CLI 工具（位于 Sources/BuddyCLI/）
- `BuddyCoreTests` (test target) — XCTest 单元测试

## 调试猫咪

Session ID 以 `debug-` 开头的猫咪会永久显示名字标签（tab name），方便在手动测试时区分调试猫和真实会话猫。

**使用 CLI**（推荐）：
```bash
buddy session start --id debug-A --cwd ~/myproject
buddy emit thinking --id debug-A
buddy session end --id debug-A
```

**使用 socket**：
```bash
echo '{"event":"session_start","session_id":"debug-A","timestamp":0,"cwd":"/tmp/a"}' | nc -U /tmp/claude-buddy.sock
echo '{"event":"session_end","session_id":"debug-A","timestamp":0,"cwd":"/tmp/a"}' | nc -U /tmp/claude-buddy.sock
```
