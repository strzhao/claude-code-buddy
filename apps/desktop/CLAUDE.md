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
│   │       ├── Calculator/                # 第三个内置插件：数学运算（priority=200）
│   │       │   ├── CalculatorPlugin.swift # BuiltinPlugin 实现：含运算符才激活 → "= 结果" 候选 → 回车复制
│   │       │   └── MathEvaluator.swift    # 纯函数递归下降求值器：+−×÷%^()，char 白名单防注入（拒字母/函数）
│   │       ├── Paste/                    # 第四个内置插件：剪贴板历史（priority=150）
│   │       │   ├── PastePlugin.swift            # BuiltinPlugin 实现：cb/剪贴板 触发 → snapshot 过滤 → Enter 回写剪贴板
│   │       │   ├── ClipboardHistoryService.swift # 常驻 Timer 0.5s 轮询 changeCount + sha8 去重 + Concealed 排除 + JSON 持久化
│   │       │   └── ClipboardHistoryItem.swift   # 条目模型（4 类型：text/image/file/html）
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

**CalculatorPlugin**（第三个内置插件，`priority=200`）：
- 输入数学表达式（`1+2*3`、`(5-3)/2`、`2^10`、`7%2`）即时出 `= 结果` 候选，Enter 复制裸结果到剪贴板
- 纯 Swift 手写 `MathEvaluator`（递归下降求值器），**不用 NSExpression / JavaScriptCore** —— 安全 / 可测 / 语义可控；char 白名单拒一切非法字符（防注入）
- 激活门控：仅当 query 含运算符字符（`looksLikeComputation`）才求值；裸数字让 `AppLauncherPlugin` 接管
- 求值失败（语法错误 / 除零 / 溢出）→ 不出候选；`CopyService` seam 可注入 Mock，测试绝不真写剪贴板
- 打分：激活即 `score=1000` 置顶（同 SystemCommand 完全匹配档）

**PastePlugin**（第四个内置插件，`priority=150`）：
- 触发词 `cb` / `clipboard` / `剪贴板` / `paste`（hasPrefix 匹配）→ 读 `ClipboardHistoryService.snapshot()` → 按 query 剩余词过滤 → 构造候选（图片用 `NSImage` 缩略图、文件取 basename、文本 50 字截断 + `…`）→ Enter 回写 `NSPasteboard`
- 四类型回写对称：text `copy` / image `copyImage` / file `copyFileURL`（`writeObjects([NSURL])`，禁用 `setString(forType:.fileURL)`——Finder 不认）/ html `copyRichText`（html + plain 双写）
- 打分：按 snapshot index 降序（`1000 - idx*10`，snapshot 已按 ts 倒序，越前越新）
- `ClipboardHistoryService` 常驻 `Timer` 0.5s 轮询 `NSPasteboard.general.changeCount`（NSPasteboard 无可靠 change 通知，轮询是行业标准，Alfred/Maccy 同款）
- 多类型读取优先级 file > image > html > text（file 最强以免复制文件时只拿到文件名）+ sha8 去重（连续重复更新 ts；非连续重复提至队首）
- **Concealed/Transient 排除**：`org.nspasteboard.ConcealedType`（密码管理器、1Password 等）/ `org.nspasteboard.TransientType` 标记的内容一律不入历史
- JSON 持久化 `~/.buddy/clipboard-history.json` + 图片 `~/.buddy/clipboard-images/<sha8>.png`
- 类型上限裁剪（text ≤500 / image ≤50）+ 30 天过期清理
- `LauncherManager.setup()` 启动时 `ClipboardHistoryService.shared.startMonitoring()`（幂等，不阻塞 UI）

**AppLauncherPlugin**（首个内置插件，`priority=0`）：
- 三个扫描目录：`/Applications`、`/System/Applications`、`~/Applications`
- 多别名索引（`AppEntry.aliases`）：索引 `CFBundleDisplayName/CFBundleName/CFBundleIdentifier 成分`，解决「微信」搜 `wechat`、「哔哩哔哩」搜 `bilibili` 搜不到的问题
- `AppMatcher` 打分：前缀(1000) > 词首连续(500) > 子序列(100)，同分按 name 字典序稳定排序
- `AppIndex` TTL=60s 后台重扫，冷启动 fire-and-forget 不阻塞 UI

**3 处交互优化**：
- Emacs 键位：`Ctrl-N` 下 / `Ctrl-P` 上，在候选列表导航
- 选中高亮：纯色 sage pill（light #3a7d68 / dark #52a688，alpha 0.92），无竖条边框
- 中文 App 可用英文名搜索（见上方多别名索引）

### 社区插件作 LLM tool（selectWithTools，2026-06-29）

**理念**：把所有「已开启的 stdin+command 社区插件」自动作为 LLM tool 暴露给 AI 路由。用户输入自然语言（「生成二维码 https://example.com」），LLM 选对插件 + 提取参数 + 执行。硬指标 = 弱模型（本地 qwen3.6-35b）执行成功率（dry-run 证明：枚举式 description 让选择正确率 90-100%，8 工具不塌方，关 thinking 必需）。

**两阶段路由改造**（`LauncherManager.submit`）：
1. 第 1 阶段（同步 keyword 缩候选）不变 —— `LauncherRouter.narrowCandidates` 仍是快速预筛。
2. 第 2 阶段从 `pickWithAI`（文本路由，LLM 回插件名）改为 `selectWithTools`（tool 路由，LLM 调 tool）：
   - `LauncherRouter.selectWithTools(query:plugins:)` → `(decision: RouteDecision, extractedQuery: String?)`
   - tools = 所有候选插件（已排除 prompt mode）的 `toAgentTool()`
   - provider.send(tools, tool_choice:"auto") → 解析 `.toolUse` → 匹配 plugin name（精确，大小写敏感，hallucinate 名→.directChat）
   - extractedQuery = `tool_call.input["query"]`（固定 {query} 契约时）；结构化 parameters 非 query 键 → nil
   - 无 tool_use → .directChat（不二次路由，防浪费 LLM 调用）
3. 执行层：`withPlugin` command mode 用 `extractedQuery ?? stripKeywordPrefix(query)` 填 PluginInput.query（LLM 提取优先，keyword 触发兜底）。stdin mode 走 agent loop，已从 tool_call input 取 query（无需改）。

**`PluginManifest.toAgentTool()` 契约**（`Plugin/PluginManifest+AgentTool.swift`）：
- description：用 `synthesizeToolDescription()`（`PluginManifest+ToolDescription.swift`）合成枚举模板 —— `<主功能(summary/desc 首句)>。触发：<keywords>。输入：query 只填要处理的内容本身（如网址、文本），不填整句话`。**提取式锚点**：弱模型倾向整句透传，必须明确要求提取内容本身，否则 `extractedQuery` 退化（cli e2e 实测旧锚点「填用户的原始请求」导致整句）；`effectiveToolInputSchema` 的固定 {query} 字段 description 同语义。弱模型靠枚举锚点匹配，禁退回空串/裸字段名。
- inputSchema：优先用 `manifest.parameters`（强制顶层 `type:"object"`，防 provider 400），缺失→回退固定 `{query}`（properties 含 query + required==["query"]）。
- **可选 `parameters` 字段**（`PluginManifest.parameters: [String: AnyCodable]?`）：插件作者声明结构化 JSON Schema（opt-in，`decodeIfPresent` 向后兼容旧 plugin.json → nil → 回退 {query}）。

**P3.0 非流式 send tools 通道**（`Provider/OpenAICompatibleProvider.swift`）：
- 非流式 `send` 补 tools 通道（对称流式 sendStream）：`OAIRequestBody` 加 `tools`/`tool_choice`（tools 非空时注入 + tool_choice:"auto"，空则都不序列化）。
- 响应解析：新建 `OAIResponseMessage`（含可选 `tool_calls`）+ `OAIResponseToolCall`/`OAIResponseToolFunction`，解析 `message.tool_calls[{id, function:{name, arguments(JSON 字符串)}}]` → `AgentContent.toolUse(id,name,input)`，与 `.text` 并存不丢弃。
- arguments 空串/畸形 JSON → soft-fail（input=空 dict），不 throw 不丢弃整个 tool_call。

**契约（C-*）**：C-TOOL-SCHEMA（inputSchema 顶层 type:object）、C-PARAM-OPTIN（parameters 可选→回退 {query}）、C-BACKCOMPAT（旧 plugin.json 解码不抛错）、C-EXTRACTED-QUERY（extractedQuery 非空→PluginInput.query==extractedQuery）、C-NO-TOOL-NO-FORGE（plugins 空→tools==[] 无伪造）、C-TOOLCALL-CHANNEL（非流式 send tools 通道不丢弃 tool_calls）、C-HALLUCINATE（tool_call.name∉plugins→.directChat）、C-THINKING-OFF（noThinking=true→body.chat_template_kwargs.enable_thinking==false）。

**延期项**：空候选纯自然语言选插件、prompt mode 作 tool、两阶段检索、dispatch 完整 permission/mode matrix。

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

### 插件开发约定（社区优先）

**新能力默认走社区插件，内置保留边界**（2026-06-28 确立）：

- **社区优先**：新功能（二维码、监控控制、文件操作等「确定性子进程产物」或「LLM 工具」）默认实现为**社区插件**，放进独立 monorepo [`strzhao/buddy-official-plugins`](https://github.com/strzhao/buddy-official-plugins)，不编进 app。
  - 优势：热更新（改 monorepo → 用户 `buddy launcher update` 即生效，不重发 app）、可审计（shell 脚本可读）、零编译（声明 deps 由 app 首次执行时自动安装）。
  - 例外：需要常驻内存 / 系统 API / 高频路径的能力才进内置（见下方边界）。
- **内置保留边界**（仅以下四类留内置，其他迁社区）：
  1. **Calculator / Paste / AppLauncher / SystemCommand** —— 已有的四个内置插件（进程内、需 NSPasteboard/NSWorkspace/登录框架等系统 API）。
  2. **lock（锁屏）等需系统私有框架的能力** —— 依赖 `login.framework` dlopen，社区插件做不到。
  3. **高频/常驻能力**（如 ClipboardHistoryService 的 Timer 轮询）—— 进程内常驻，社区插件是按需 spawn 的短命子进程。
  4. **核心路由/仲裁**（LauncherManager / BuiltinPluginRegistry / Router）—— 框架本身，非插件。
- **社区插件技术栈**：
  - **command mode**（零 LLM、子进程直接产出）：适合二维码、截图、文件转换等确定性输出。脚本读 stdin JSON `$INPUT=$(cat)` + `jq -r '.query // ""'` 取 query，产出写 `$BUDDY_OUTPUT_IMAGE`（图片）或 `$BUDDY_OUTPUT_CANDIDATES`（候选）或 stdout（文本）。
  - **stdin mode**（子进程 stdout 回灌 LLM）：适合「LLM 调用工具」语义。
  - **prompt mode**（LLM 单轮）：适合翻译、问答、改写。
  - 外部依赖走 `deps` 声明（`{check, brew, label}`），app 首次执行时弹信任框 + 自动 `brew install`（见 DependencyInstaller/TrustPrompt）。

**官方插件 monorepo**：`~/workspace/buddy-official-plugins`（与 app repo 同级的 workspace clone），结构 `plugins/<name>/{plugin.json, 主脚本, README.md}` + 根 `marketplace.json`。

**本地开发循环**（改 monorepo → 立即在 app 生效，免 git push）：

```bash
# 在 apps/desktop 下：
make fetch-plugins-local                    # 从本地 clone 拉（默认 ~/workspace/buddy-official-plugins）
make fetch-plugins-local BUDDY_LOCAL_PLUGINS_DIR=/path/to/clone   # override clone 路径
make fetch-plugins                          # 从 GitHub main 拉（验证发版链路）
SKIP_FETCH_PLUGINS=1 make build             # 跳过 fetch（离线调试，需已有 plugins/ 内容）
```

build-time fetch 机制：Makefile `fetch-plugins` → `Scripts/fetch-plugins.sh` 从 monorepo git clone 拉取 `plugins/` 源 + 生成 bundle `marketplace.json`，填进 `Sources/ClaudeCodeBuddy/Marketplace/plugins/`（构建产物，.gitignore 忽略）。`BUDDY_OFFICIAL_PLUGINS_URL=file:///path` 可指向任意本地/远程 monorepo。

**release 链路**（C1）：`.github/workflows/release.yml` 在 `Build arm64` 前有 `make -C apps/desktop fetch-plugins` step，保证发版带插件（fetch 失败令 CI 失败，非静默）。

### 插件管理

```bash
buddy launcher add <user>/<repo>                   # git clone --depth 1
buddy launcher list                                # 已装插件 + trust 状态 + summary
buddy launcher inspect <name>                      # JSON 详情（含 summary/description）
buddy launcher remove <name>                       # 卸载 + 清 trust
buddy launcher run <name> --input "xxx" [--json]   # dry-run 直接执行具名插件（不经候选路由）
```

**插件开发文档**：web 端 `/plugin/docs`（人类可读 + 「复制给 AI 使用」单按钮复制完整自包含指南）。
设置页「插件」分区右上角「插件开发文档」按钮 → `NSWorkspace.open` 打开。

### 插件 summary / description 写作规范（契约 C1/C2）

`plugin.json` 加 `summary`（可选，一句话人话摘要）+ 保留 `description`（详细）。
`BuiltinPlugin` 协议也加 `summary`/`description`。

**降级规则**（SOURCE OF TRUTH: `PluginManifest.displaySummary`）：
展示用 summary 取值优先级 = `summary` 非空 → summary；否则 `description` 首句（按 `。`/`. `/换行切第一段 trim）；都空 → `name`。
展示层永远拿到非空 summary。加载层不拒绝无 summary 的插件（向后兼容）。
CLI mirror `cliDisplaySummary` 同语义（C5 双绑，`cliFirstSentence` 与 `firstSentence` 逐字一致）。

**写作要求**：summary 写给人看，禁黑话（stdin/stdout/协议/内部代号/裸字段名）。
官方插件（hello/qr/qzh + 4 内置）强制填人话 summary。

### 内置插件开关（契约 C3）

内置插件（calculator/paste/system-command/app-launcher）开关独立于外部插件：
- 存储：`UserDefaults.standard`，key `buddy.launcher.builtin.<id>.disabled`（Bool，true=关闭）。
- API：`BuiltinPluginEnabledStore.isEnabled(id:)` / `setEnabled(id:enabled:)`。默认全 enabled。
- 关闭语义：`BuiltinPluginRegistry.actions(for:)` 跳过 disabled（不产生候选/不响应）。
- **Paste 关闭语义**：仅阻断候选展示，`ClipboardHistoryService` Timer 仍记录剪贴板（YAGNI，设置页有 tooltip 说明）。
- 外部插件开关仍走 `.disabled` 文件（`PluginManager.enable/disable`），两套独立。

### 调试（功能调试，不经键盘自动化）

```bash
buddy launcher debug candidates <query>            # 生成内置插件候选（JSON）
buddy launcher debug perform <query> [--index N]   # 执行第 N 个候选并读剪贴板（默认 N=0）
buddy launcher debug registry                      # 列出已注册内置插件（priority 降序，JSON）
buddy launcher debug route <query>                 # AI 路由调试：query → narrow → debugRoute(selectWithTools/pickWithAI) → LLM 响应（JSON）
buddy launcher run <name> --input "xxx" [--json]   # dry-run 直接执行具名外部插件（含 TOFU）
buddy log show --subsystem plugin                  # 看插件子系统日志
```

**用途**：功能调试 / 无侵入测试。CLI 直接驱动候选生成，**不经键盘自动化**（避免 osascript 抢屏幕的问题）。

**实现**：CLI 通过 socket 让 app 进程调 `BuiltinPluginRegistry`（**直驱，不经 LauncherManager**），由 `QueryHandler.handle`（async）处理 `launcher_debug_*` action。

**响应契约**：
- `candidates` → `{status:"ok", data:{query, count, candidates:[{pluginId, title, subtitle, score}]}}`
- `perform` → `{status:"ok", data:{pluginId, performed:true, copied?}}`（`copied` 仅当 perform 后 pasteboard 非空才返回）
- `registry` → `{status:"ok", data:{plugins:[{id, priority, sectionTitle, summary, enabled}]}}`（priority 降序；C2/C3 含 summary + enabled）
- `route` → `{status:"ok", data:{query, decision, candidates:[{name, score, mode}], outputText, durationMs, routeMethod, extractedQuery?}}`（端到端 AI 路由调试；绕过 LauncherManager.submit 的 isSubmitting 卫兵，在 handler 上下文直接调 ProviderFactory + LauncherRouter.debugRoute + PromptExecutor。**debugRoute 镜像 submit 分支**：含 tool 候选→`selectWithTools`（`routeMethod:"selectWithTools"` + `extractedQuery` 回传 LLM 从 tool_call 提取的参数）/ 全 prompt 候选→`pickWithAI`（`routeMethod:"pickWithAI"`）/ 空候选→`directChat`。修复 e2a65ca 后 debug route 仍走旧 pickWithAI 的缺口，使 tool-use 路径在 cli 下可验证）
- `run` → `{status:"ok", data:{name, stdout, stderr, exit_code, duration_ms}}`（C4；trust 失败 → `{status:"error", message:"not trusted"}` + CLI exit 非 0）

**run 与 debug perform 区别**：run 是 name→直接 execute（不经候选路由），跑外部子进程插件；debug perform 是 query→candidates→perform N，跑内置 in-process 插件。run 必须经 `TrustStore.checkAndPrompt`（B1，TOFU 不绕过）。

### TOFU 安全模型

首次执行插件弹 NSAlert 确认。`trustKey = SHA256(cmd + args + sha256(executable bytes))`，任一改动（含二进制内容）使旧信任失效，强制重新弹框。trust 记录：`~/.buddy/launcher-trust.json`（0644）。

**mode 前缀隔离**：trustKey 带 mode 前缀（`stdin:` / `command:` / `prompt:`），即使 cmd/args/exe 完全相同，不同 mode 的 trustKey 也不同，防止 stdin 已信任的 plugin 被冒充成 command mode 跳过 TOFU。

### 三种插件 mode + 通用图片通道

`PluginModeConfig` 三个 case，对应三种执行模型：

- **stdin**：子进程 stdout 经 toolExecutor 回灌 LLM（agent loop），适合「LLM 调用工具」语义。
- **prompt**：bypass agent loop，直接调 PromptExecutor（LLM 单轮），结果映射为 `.text` + render-only `.action` 按钮。
- **command**（新增）：零 LLM、bypass agent loop，子进程直接产出。`LauncherManager.submit` switch 加 `.command` 分支提前 return，不构造 LauncherAgent、不发 LLM 请求。适合确定性子进程产物（二维码、截图等）。

**通用图片通道**（stdin + command 共享）：`StdinExecutor` 注入环境变量 `BUDDY_OUTPUT_IMAGE=/tmp/buddy-plugin-<uuid>.png`，子进程写 PNG，框架读文件成 `Data` 填 `PluginResult.image`。stdout 保持纯文本不被污染。

- 读前校验 `resolvedPath == outputImagePath`（防 symlink，/tmp 防御）
- `count > pluginMaxImageBytes`（5MiB）→ image = nil（丢弃，不报错）
- finally 删临时文件（防累积，多次触发不无限增长）
- 文件不存在/读失败 → image = nil（降级）

UI：`AgentEvent.image(Data)` → `NSImage(data:)` → 居中白底 200pt 卡片（白底保证扫码对比度），点击 → `CopyService.copyImage`（clearContents + setData .png）+ ✓ 反馈（1.2s 复位）。无图片无 stdout 时显示占位「未生成图片」。

**qr 插件（command mode 首个用例，社区插件）**：`plugins/qr/qr-gen.sh`（shell 脚本）调 `qrencode -s 24 -m 2 -l M` 生成 ≥480px PNG 写 `$BUDDY_OUTPUT_IMAGE`。声明 `deps: [qrencode, jq]`，首次执行时 app 弹信任框 + 自动 `brew install`。v0.2.0 从编译型 universal binary（CoreImage）改为 shell 脚本（qrencode），随官方插件 monorepo build-time fetch 分发。

### 通用候选输出通道 + 选中回调重入

**候选输出通道**（command mode，对称 `BUDDY_OUTPUT_IMAGE`）：`StdinExecutor` 注入环境变量 `BUDDY_OUTPUT_CANDIDATES=/tmp/buddy-plugin-<uuid>.json`，子进程写候选 JSON 数组 `[{id, title, subtitle?, selection}]`，框架 `readCandidatesOutputSafely` 安全读取解码为 `[LauncherCandidate]` → `PluginResult.candidates` → `AgentEvent.candidates`。stdout 保持纯文本不被污染。

- 读前校验 `resolvedPath == outputCandidatesPath`（防 symlink，/tmp 防御）
- `count > pluginMaxCandidatesBytes`（64 KiB）→ candidates = nil（丢弃，不报错）
- JSON 解码失败 / 字段缺失 → candidates = nil（降级，候选可选）
- finally 删临时文件（防累积）

**选中回调重入**（`LauncherManager.submitWithCandidate(_:selection:query:)`）：用户从候选列表选中某项后，以 `LauncherCandidate.selection` 填入 `PluginInput.selection` 重入同插件（bypass LLM，执行选中动作如 stop/start）。

- 仅 command mode 支持（stdin/prompt 调用报错返回 `.pluginCrash`）
- command trustKey 不含 selection 字段 —— 回调不重复弹 TOFU 框（首次查询已 trust 则选中回调直接放行）
- 执行权始终留在插件：launcher 只透传 selection，不做任何动作解释

**候选 UI**（`LauncherPluginCandidateView`）：渲染 `AgentEvent.candidates` 收集的 `[LauncherCandidate]`，每行 title + subtitle，↑↓ 导航 + Enter / 点击触发 `submitWithCandidate` 回调。沿用 Raycast 视觉语言（对称 image 通道的白底卡片风格）。

**qzh 插件**（首个候选通道使用者，`Marketplace/plugins/qzh/`）：command mode，查询 QzhddrSrv 监控软件状态 + [关闭监控 / 打开监控] 候选点选。

- 首次查询（`PluginInput.selection` 空）：`pgrep` + `launchctl print` 查 service/update 双进程状态 → 写候选 JSON 到 `$BUDDY_OUTPUT_CANDIDATES`
- 选中「关闭」/「打开」：`launchctl bootout` / `bootstrap` system 级 LaunchDaemon（`com.cyberserval.qzhddr.service` + `.update`）
- sudo 免密：`setup.sh` 一次性写 `/etc/sudoers.d/qzhddr-launcher`，`%admin ALL=(root) NOPASSWD: launchctl bootout/bootstrap ...` 精确匹配（非绝对路径 `launchctl` 放行，无通配 / 无任意 label / 无任意参数），写入前 `visudo -c` 语法校验
- 可逆：bootout 只卸载不删 plist，bootstrap 可重新拉起

### command 路由候选分区（方案 B，2026-06-20）

**背景**：qzh command 插件落地后发现路由冲突——输入 `qzh` 时内置 instant 候选（AppLauncher 匹配 Qzhddr.app）与 router 命中的外部 command 插件（qzh）**互斥且 instant 抢占**，command 插件既不显示为候选行，Enter 又被 instant 优先执行（打开 app），用户主动安装的 command 插件**完全不可达**。

**方案 B 分区渲染**：恢复 command 路由候选为候选行，与 instant 候选**分区同时展示**，command 区在上、Enter 优先。改动聚焦展示层 + Enter 选择 + 导航，**不动** submit 管线核心 / StdinExecutor / 候选输出通道 / TOFU。

**数据层**（`LauncherManager`）：
- `@Published commandRouteCandidates: [PluginManifest]` —— typing 阶段填充的 command-mode 子集（`updateQuery` 由 `narrowed.filter{ if case .command = $0.modeConfig }` 算出）
- `@Published commandRouteSelectedIndex: Int` —— 默认 0（command 优先选中），空时 -1
- `@Published activeCandidateZone: CandidateZone` —— 导航活动区枚举 {.pluginCandidates, .commandRoute, .instant, .aiRoute}，决定 ↑↓ 跨区语义与 Enter 派发
- 测试 seam：`pluginsOverride: [PluginManifest]?`（注入 plugins 源，I1）/ `stdinExecutorOverride: StdinExecutor?`（submitCommandDirect spy，I6）
- 复位点：空 query / show / hide / clearInstantActions / command 执行开始（stage→calling）清空

**command 短路执行入口**（`submitCommandDirect(_:query:) -> AsyncStream<AgentEvent>`，C11）：镜像 `submit()` 内 `.command` case + 顶层 command 短路的执行段——`guard case .command` → prologue（清 commandRouteCandidates + stage=.calling）→ detached: trust checkAndPrompt → `PluginDispatcher(stdinExecutor: stdinExecutorOverride ?? .shared).execute` → yield `.text`/`.image`/`.candidates`/`.done` → stage streaming→idle。**零 provider / 零 LLM**（与 `submitWithPlugin` 区别：后者强制 provider + LLM agent loop）。对称 `submitWithCandidate`（command 回调入口）。

**渲染层**（`LauncherInputView`）：
- `showCommandRouteCandidates` 计算属性（stage ∈ {idle,narrowing,routing} && !hasOutput && commandRouteCandidates 非空）
- 分区顺序（自上而下）：command 路由区（`LauncherCandidateView`，恢复死代码 + 加 `onSelect` 回调）→ instant 区 → pluginCandidates 输出通道区
- 两区同时渲染（commandRoute + instant 并存）

**导航**（C5 四态矩阵）：↑↓ 按 `activeCandidateZone` 派发。pluginCandidates 通道非空（post-exec）→ 仅区内环形隔离；commandRoute + instant 并存 → 区内环形 + 边界跨区（commandRoute 末↓→instant 首，instant 首↑→commandRoute 末）；仅单区 → 区内环形（C10 回归）。

**Enter 优先级**（C4）：`submit()` 按 `activeCandidateZone` 派发——.commandRoute → `submitCommandDirect` return；.instant → `performSelectedInstantAction`；空 → pluginCandidates 通道回调 → AI 路由。默认 activeCandidateZone=.commandRoute（command 优先）。

**面板高度**（`panelHeight` C6 四态公式，取代既有 max 互斥）：output 态 / 候选并存态（commandRouteExtra + instantExtra **叠加**）/ 仅单区态（C10 回归）/ 空态。



### 故障排查

- **快捷键被占用/失效** → `buddy launcher hotkey show` 查看当前热键 + 是否默认，或打开设置面板「热键」tab 用 RecorderCocoa 改键；`buddy launcher hotkey clear` 重置为默认 (Ctrl+Space)
- **trust.json 损坏** → 删除 `~/.buddy/launcher-trust.json`，下次执行重新弹框
- **SecretStore 探针降级** → ad-hoc 签名时自动从 Keychain 降级到 EncryptedFile；查 logs `LauncherSecretStore probe failed`
- **plugin 安装失败 exit 1** → 检查网络 / `git clone` 60s 超时
- **plugin manifest 无效 exit 2** → 查看 `plugin.json` 是否符合 PluginManifest schema（cmd 不含 `..` 或绝对路径）

## 设置窗口子系统（task 013，2026-06-23）

macOS 原生系统设置风格：`NSSplitViewController` 左 sidebar 分类导航 + 右 detail 容器 containment 切换。正经产品感优先（参考 macOSSettings.app 布局），替换旧 `NSSegmentedControl` 三 tab。

**目录结构**（`Sources/ClaudeCodeBuddy/Settings/`）：
- `SettingsSection.swift` — 分类枚举（skins/plugins/hotkey/general/about），`CaseIterable` 单一数据源。**加分类 = 加一个 case**，窗口/splitVC/sidebar 初始化禁按分类数量 switch/if 硬编码（SC-12 旁证）
- `SettingsSidebarViewController.swift` — `NSTableView` 数据驱动；`didAdd rowView` 设 AX id（契约 7：AXRow 层设 id，cellView 的 id 在 row 层读不到）
- `SettingsSplitViewController.swift` — detail 容器 containment 切换 child VC；detail AX 锚点设在 child root view（容器 view 被 child 遮蔽）
- `SettingsWindowController.swift` — 标准 `NSWindow`（不再是 `NSPanel`）+ `SettingsWindow` 子类 sendEvent 兜底
- `GeneralSettingsViewController.swift` — 音效/标签开关（从 SkinGallery 迁入）+ `SMAppService` 开机自启
- `AboutSettingsViewController.swift` — 版本/反馈/开源
- `SkinGalleryViewController.swift` / `KeyboardShortcutsViewController.swift` / `PluginGalleryViewController.swift` — 作为 detail child VC 复用

**LSUIElement key window 兜底（R1 教训，2026-06-23）**：

LSUIElement accessory policy 下标准 `NSWindow` 可能不成为 key window，致 `NSTableView` 鼠标选中失效（与 `patterns/2026-04-19` LSUIElement 窗口交互同根因）。`SettingsWindow.sendEvent` 拦截 `leftMouseDown` 双兜底：
- `forwardSidebarClick`：`hitTest` 上溯到 `NSTableView` 后手动 `selectRowIndexes`（→ `tableViewSelectionDidChange` → detail 切换）
- `forwardDetailClick`：`NSCollectionView isSelectable=false`（SkinGallery）系统不选中，走 responder chain 找 `SettingsTabClickReceiver.handleClickAt` 手动命中（复用旧 SettingsPanel 机制）

`AppDelegate.showSettings` 顺序：先 `NSApp.activate()`（macOS 14+ 新 API，旧 `activate(ignoringOtherApps:)` 对 accessory policy 可能 no-op）→ `showWindow` → `makeKeyAndOrderFront`。历史 `SettingsPanel` 作安全网保留不删。

**AX 契约**（红队 SC-01..16 守护）：sidebar row id `settings.sidebar.{section}`、detail id `settings.detail`、窗口 title `设置`。蓝队单测 8 + 红队验收 26。

## 日志系统（task 014，2026-06-24）

统一日志系统：JSON Lines 落盘 + CLI 取阅 + 收编所有 `print`/`NSLog`。**后续所有开发日志必须用 `BuddyLogger`，禁止裸 `print`/`NSLog`。**

### 使用 Logger

```swift
import BuddyCore   // 或同 module 内直接用

BuddyLogger.shared.info("启动完成", subsystem: "app", meta: ["version": "1.0"])
BuddyLogger.shared.warn("provider 降级", subsystem: "launcher", meta: ["reason": "timeout"])
BuddyLogger.shared.error("socket 失败", subsystem: "socket", meta: ["errno": "ECONNREFUSED"])
BuddyLogger.shared.debug("状态切换", subsystem: "state-machine", meta: ["from": "idle", "to": "thinking"])
```

API（契约 C3）：
- `BuddyLogger.shared.{debug|info|warn|error}(_ msg: String, subsystem: String, meta: [String: Any]? = nil)`
- `subsystem` 必填，`meta` 可选（结构化键值对，会写入 JSON `meta` 字段）
- 线程安全（内部串行队列），容错不崩（IO 失败静默降级）

**禁止**：`print()`、`NSLog()`、`os_log` 裸调用。新增代码用 `BuddyLogger`。

### 子系统标签（契约 C6，新增须登记到本表）

| subsystem | 用途 |
|---|---|
| `app` | AppDelegate / 生命周期 / 通知 / 更新 / 窗口边界 |
| `state-machine` | 猫咪状态机 / 动画 / 食物 / 边界恢复 |
| `launcher` | LauncherManager / Router / 热键 / marketplace |
| `launcher-agent` | LLM 调用 / PromptExecutor / Agent loop |
| `plugin` | PluginManager / MarketplaceManager / 安装/迁移 |
| `socket` | SocketServer / IPC 收发 |
| `session` | SessionManager / 会话生命周期 |
| `skin` | SkinPackManager |
| `settings` | 设置窗口 / 开关 / 热键录制 |
| `builtin` | 内置插件候选生成/执行（Calculator/System/AppLauncher/Paste） |
| `clipboard` | ClipboardHistoryService |

### CLI 取阅日志

```bash
buddy log path                              # 当前日志文件绝对路径
buddy log show                              # 全部日志（人类可读摘要）
buddy log show --json                       # 原始 JSONL（jq 友好）
buddy log show --level warn                 # warn 及以上
buddy log show --subsystem launcher         # 精确匹配子系统
buddy log show --since 1h                   # 最近 1 小时（Nh/Nm/Nd）
buddy log show --lines 50                   # 最后 50 行
buddy log tail [--lines N] [--follow]       # 最近 N 行 / 实时跟随
buddy log grep <pattern> [--level L] [-i]   # msg 匹配
buddy log clear [--yes]                     # 归档当前文件并新建

# 组合示例（AI 分析常用）
buddy log show --json | jq -r 'select(.level=="error") | .msg'
buddy log show --subsystem socket --since 30m
buddy log grep "失败" --level error
```

**app 未运行也能查**（契约 C4 / 场景 4）：CLI 直接读文件，崩溃后排查最关键。

### 日志文件契约（契约 C1）

- 目录：`$HOME/.buddy/logs/`（权限 0700）；可被 `BUDDY_LOG_DIR` 环境变量覆盖（测试隔离）
- 当前文件：`$HOME/.buddy/logs/buddy.jsonl`（权限 0600）
- 归档：`buddy-<YYYYMMDD-HHMMSS>.jsonl`（时间戳，永不覆盖）
- 格式：JSON Lines，每行 `{"ts","level","subsystem","msg"[,"meta"]}`
- 轮转：当前文件 > 5 MiB 时归档并新建
- 保留：目录总占用 > 50 MiB 或归档 > 30 个时删除最旧归档

### debug / release 级别差异（契约 C2）

级别解析优先级（`LogConfig.resolveMinLevel`）：
1. `BUDDY_LOG_LEVEL` 环境变量（`debug|info|warn|error|off`）—— 一律覆盖
2. `#if DEBUG` → `debug`（全量）；release → `info`（过滤 debug 噪音）
3. `RuntimeEnvironment.isRunningTests` → `off`（XCTest 宿主默认关）

**release 也写日志**（用户确认）：默认 info 级落盘，便于线上排查。

### 新增/修改日志位置

- BuddyCore 实现：`Sources/ClaudeCodeBuddy/Logging/{BuddyLogger,LogLevel,LogConfig,LogWriter}.swift`
- CLI 实现：`Sources/BuddyCLI/main.swift` 的 `log` 命令组 + 路径常量 mirror（⚠️ MIRROR LogConfig，契约 C5）
- 单元测试：`tests/BuddyCoreTests/Logging/`（BuddyLoggerTests / LogConfigAndWriterTests / BuddyLogCLIUnitTests / LogConfigEnvAndIsolationTests）
- 迭代：`make test-only FILTER=BuddyLoggerTests`（秒级，不要跑全量）

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
