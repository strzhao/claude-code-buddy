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
│   │       ├── System/                   # 第二个内置插件：系统命令（task 012）
   │       │   ├── SystemCommandPlugin.swift  # BuiltinPlugin 实现：lock 命令 → 锁屏（priority=100）
   │       │   └── ScreenLocking.swift    # seam 协议：生产 LoginFrameworkScreenLocker / 测试 Mock
   │       └── AppLauncher/              # 首个内置插件：搜索打开 App
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

Alfred 式 AI 启动器：Ctrl+Space 召唤浮窗 + AI 路由 + CLI 插件。**与像素猫互不干扰**（独立 NSPanel + 独立配置目录 `~/.buddy/` + 静态隔离测试 SC-10）。

**热键配置（2026-06-15）**：默认键从 ⌘⇧Space 改为 Ctrl+Space（参考 Alfred 大而方便）。热键存储由 KeyboardShortcuts 库的 UserDefaults 单一真相源管理（key `KeyboardShortcuts_launcher-toggle`），不在 launcher.json 双轨存储。三入口改键：① 设置面板「热键」tab（Alfred 风格大 RecorderCocoa + 重置按钮）；② `buddy launcher hotkey set/show/clear` CLI；③ app 启动迁移 `launcher.hotkeyMigrationV1` 清理旧不兼容值。重置一律用 `KeyboardShortcuts.reset(.toggle)`（回 default），禁用 `setShortcut(nil)`（清除非回 default）。

**视觉风格（task 010）**: Apple HIG / Raycast 风格。`VisualEffectBackground`（NSVisualEffectView .menu/.behindWindow 的 SwiftUI 包装）单层毛玻璃，16pt 圆角，spring 入场动画，SF Symbol 选中指示器（chevron.right.fill + 左侧 sage Capsule 竖条），全 .rounded 字体规范。**注**：曾用 SwiftUI `.ultraThinMaterial`，但其 light/dark 依赖 `@Environment(\.colorScheme)`，在 NSPanel+`hidesOnDeactivate` 浮窗里传播不可靠，浅色模式整块渲染异常（毛玻璃发灰、结果区白方块）；改用 `NSVisualEffectView` 按 `effectiveAppearance` 求值，浅深色一致。结果输出区透明、与输入行共用同一块毛玻璃。

**Loading 反馈**: 回车执行时不再有外挂 pulse dots / 「正在处理」文案，改为 `LauncherLoadingBorder` —— 沿面板圆角边框「周长弧长参数化」匀速跑一道单彗星流光（`TimelineView(.animation)` + `Canvas`，单次 stroke + 沿线 linearGradient，连续无珠子）。遵守测试冻结铁律：`RuntimeEnvironment.isRunningTests || reduceMotion` 时渲染静态帧不启逐帧循环（见下方测试坑 2）。

### 内置插件体系（task 011）

**即时候选管线**：输入时 debounce(120ms) 后查询 `BuiltinPluginRegistry`，`instantActions` 非空时优先显示内置候选（Raycast 风行布局），按 Enter 直接执行，无匹配则落回 AI 流。

**BuiltinPlugin 协议** — 所有内置能力统一实现：
- `id`：插件唯一标识
- `priority`：仲裁权重（同 query 多插件并发，按优先级分区）
- `sectionTitle`：候选列表分区标题
- `actions(for:) async -> [LauncherAction]`：返回候选动作列表

**SystemCommandPlugin**（第二个内置插件，`priority=100`，task 012）：
- 关键词匹配：`lock` / `锁屏` → 「锁定屏幕」候选，Enter 直接锁屏
- 通过 `login.framework` 私有框架 `SACLockScreenImmediate` 动态 dlopen 锁屏（无需额外 TCC 权限）
- `ScreenLocking` 协议可注入 Mock，测试绝不真锁屏
- 打分：完全匹配 1000，前缀匹配 800

**AppLauncherPlugin**（首个内置插件，`priority=0`）：
- 三个扫描目录：`/Applications`、`/System/Applications`、`~/Applications`
- 多别名索引（`AppEntry.aliases`）：索引 `CFBundleDisplayName/CFBundleName/CFBundleIdentifier 成分`，解决「微信」搜 `wechat`、「哔哩哔哩」搜 `bilibili` 搜不到的问题
- `AppMatcher` 打分：前缀(1000) > 词首连续(500) > 子序列(100)，同分按 name 字典序稳定排序
- `AppIndex` TTL=60s 后台重扫，冷启动 fire-and-forget 不阻塞 UI

**3 处交互优化**：
- Emacs 键位：`Ctrl-N` 下 / `Ctrl-P` 上，在候选列表导航
- 选中高亮：纯色 sage pill（light #3a7d68 / dark #52a688，alpha 0.92），无竖条边框
- 中文 App 可用英文名搜索（见上方多别名索引）

### Render-only meta tool 体系（attach_action）

**理念**：交互动作（朗读/复制等）做成框架内置的 **render-only meta tool**，注入给所有 prompt mode 调用（含默认流 + 所有 prompt 插件）。模型调用 tool ≠ 立即执行 —— 它只是「声明一个按钮」，UI 渲染成可点击入口，用户点击才触发。这与 agent/stdin mode 的「真执行 + 回灌结果」工具语义相反。

**为什么不再用 `<action:>` 标签**：旧方案靠 prompt 硬规则让 LLM 在正文里嵌 `<action:speak>` 标签，再解析成内联按钮。问题：① 译文被塞进按钮 text 属性、正文不可见；② 一段一行 VStack 把输出切碎；③ 依赖模型守标签格式，易飘。已彻底删除（`MarkdownActionParser` / `ActionSegment` / `ActionSegmentsView` / `ActionButton`）。

**meta tool 定义**（`Launcher/Action/MetaTools.swift`）：
- `attach_action(kind: speak|copy, text, label?)` —— 固定闭集，后续渐增 kind
- description 用**枚举式锚点**（列「每段英文配 speak / 译文·代码·命令配 copy」「闲聊·解释·追问不挂」），本地 qwen 实测比 claude-code 的「内核式原则」写法稳（弱模型需具体锚点，见 dry-run 结论）
- `LauncherActionButton`（值类型）+ `LauncherActionKind`：从 tool_call JSON 解析，未知 kind / 缺 text → soft-fail 丢弃

**渲染**（`Launcher/Action/LauncherActionBar.swift`）：
- 正文走干净 `MarkdownRenderer` 连续渲染（译文永远可见）
- 按钮全部收进**底部统一工具条** `LauncherActionBar`：1px hairline 分隔 + `FlowLayout` 横向排 `LauncherActionChip`（sage 胶囊、毛玻璃轻填充、hover 加深、copy 点击反馈「✓ 已复制」）

**服务层**（`Launcher/Service/`）：
- `SpeechService`：`AVSpeechSynthesizer` 朗读英文 TTS
- `CopyService`：`NSPasteboard` 写剪贴板

**流式 tool_calls 解析**（`OpenAICompatibleProvider`）：
- `parseSSELines` 按 `index` 累积 `delta.tool_calls[].function.arguments` 碎片，`[DONE]` 时解析每个 index → emit `ProviderChunk.action`
- 请求体 `tools` 由框架 `AgentTool` 转 OpenAI `{type:function, function:{...}}` 格式
- `ProviderChunk` 加 `.action` case；`AgentEvent` 加 `.action` case；`PluginResult` 加 `actions` 字段

**默认流（directChat）= AI native Alfred**（`MetaTools.DefaultAgentPrompt`）：
- 用户未命中插件 → Buddy「万能输入框」system prompt（极简单一指令，自适应翻译/查词/问答/改写/代码）
- 走 `PromptExecutor` 单轮路径（非 agent loop）+ 注入 meta tools
- **翻译/查词已折进默认流**：不再有单独的 translate 插件、无需触发词

**P0 thinking off**（保留）：Qwen3 等推理模型通过 `chat_template_kwargs.enable_thinking=false` 关 CoT，只有此通道生效（top-level/user-flag 被服务端忽略）。TTFT 24.5s→0.038s。

**P0.1 Router 短路**（保留）：唯一命中或 score≥10(`routerSkipScore`) 跳过 router LLM call。

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

### 热键配置（2026-06-15）

```bash
buddy launcher hotkey show                              # 查看当前热键 + isDefault
buddy launcher hotkey set --key space --modifiers control    # 设置为 Ctrl+Space
buddy launcher hotkey set --key p --modifiers command,shift # 设置为 ⌘⇧P
buddy launcher hotkey clear                             # 重置为默认 (Ctrl+Space)
```

参数：`--key <key>`（字母 a-z / 数字 0-9 / space / f1-f20 / return 等）+ `--modifiers <csv>`（command,shift,control,option）。
CLI 通过 socket 让 app 进程调 KeyboardShortcuts 库 API，即时重注册 Carbon 热键（无需重启 app）。

### 插件管理

```bash
buddy launcher add <user>/<repo>                   # git clone --depth 1
buddy launcher list                                # 已装插件 + trust 状态
buddy launcher inspect <name>                      # JSON 详情
buddy launcher remove <name>                       # 卸载 + 清 trust
```

### TOFU 安全模型

首次执行插件弹 NSAlert 确认。`trustKey = SHA256(cmd + args + sha256(executable bytes))`，任一改动（含二进制内容）使旧信任失效，强制重新弹框。trust 记录：`~/.buddy/launcher-trust.json`（0644）。

### 故障排查

- **快捷键被占用/失效** → `buddy launcher hotkey show` 查看当前热键 + 是否默认，或打开设置面板「热键」tab 用 RecorderCocoa 改键；`buddy launcher hotkey clear` 重置为默认 (Ctrl+Space)
- **trust.json 损坏** → 删除 `~/.buddy/launcher-trust.json`，下次执行重新弹框
- **SecretStore 探针降级** → ad-hoc 签名时自动从 Keychain 降级到 EncryptedFile；查 logs `LauncherSecretStore probe failed`
- **plugin 安装失败 exit 1** → 检查网络 / `git clone` 60s 超时
- **plugin manifest 无效 exit 2** → 查看 `plugin.json` 是否符合 PluginManifest schema（cmd 不含 `..` 或绝对路径）

## 开发

```bash
make build          # 编译 debug
make run            # 编译并启动
make test           # 全量单元测试（走看门狗，flaky 死锁会超时失败而非挂死，见下方「测试」）
make test-launcher  # ⚡ 只跑 launcher 子系统全部测试（开发 launcher 用，不跑猫咪/皮肤/session）
make test-fast      # ⚡ 快速逻辑回归：跳过窗口/快照/SpriteKit 等重量级类
make test-only FILTER=<类名>   # ⚡ 只跑某个测试类（迭代单模块，秒级）
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

- `make test` — 全量单元测试，**走看门狗** (`Scripts/test-watchdog.sh`)：超过 `TEST_TIMEOUT`（默认 600s）判定挂死并终止，避免 flaky 死锁把本地/CI 挂死数小时
- `make test-launcher` — ⚡ 只跑 launcher 子系统全部测试（`tests/BuddyCoreTests/Launcher/` 下所有类，从目录动态生成 `--filter`，自动覆盖新增类）。开发 launcher 时用，不跑猫咪/皮肤/session/socket 等无关测试
- `make test-fast` — ⚡ 快速逻辑回归，跳过窗口/快照/SpriteKit/socket 等重量级类（这些被 `@MainActor` 钉在主线程串行，是全量慢的主因）
- `make test-only FILTER=<类名>` — ⚡ 只跑指定测试类，迭代单模块用（秒级）
- `swift test --filter Snapshot` — 视觉快照回归测试
- `tests/acceptance/run-all.sh` — Shell 验收测试
- CLI 自动测试: `buddy test --delay 2` — 遍历所有状态

### ⚠️ 迭代加速与两个坑

**坑 1：`--filter`/`--skip` 匹配的是「测试类名」，不是文件名。**
例如文件 `LauncherRouterAcceptanceTests.swift` 里的类其实叫 `RouteDecisionEquatableTests`。
查类名：`grep -rh 'final class .*: XCTestCase' Tests/`。

**坑 2：永不终止的 SwiftUI 动画会在测试中空转 RunLoop 导致挂死。**
`TimelineView(.animation)`（如 `LauncherPulseDots`）逐帧重绘永不停止；被 host 进测试窗口后残留，
后续测试泵 RunLoop 时把 CFRunLoop 拖入 100% CPU 无限空转，曾导致 `swift test` 偶发挂死数小时。
**规约**：此类动画必须用 `RuntimeEnvironment.isRunningTests` 在测试下冻结为静态帧（见 `LauncherPulseDots.swift`）。
新增逐帧动画视图时务必遵循；`RuntimeEnvironmentTests` 守护探测逻辑不被破坏。

**迭代闭环**：改 launcher → `make test-only FILTER=<你在改的类>`（~5s，含增量编译）。
编译不是瓶颈（增量 ~1-5s），瓶颈是全量跑 87 个串行 UI 测试 + 上述 flaky 挂死。

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
