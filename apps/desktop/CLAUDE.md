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
│   ├── Launcher/       # Alfred 式 AI 启动器: LauncherManager, LauncherWindow, LauncherInputView
│   ├── Window/         # 窗口: BuddyWindow, DockTracker, MouseTracker
│   ├── MenuBar/        # 状态栏弹窗: SessionPopoverController
│   ├── Assets/Sprites/ # 48x48 像素猫咪精灵图
│   └── Resources/      # Info.plist
└── App/                # App 可执行文件入口 (main.swift)
```

**数据流**: Claude Code Hook → buddy-hook.sh → Unix Socket → SocketServer → SessionManager → EventBus → BuddyScene/CatSprite

**猫咪状态机** (GKStateMachine): CatIdleState(sleep/breathe/blink/clean) → CatThinkingState(paw+sway) → CatToolUseState(random walk) → CatPermissionRequestState(alert+badge) → CatEatingState

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
