# Claude Code Buddy

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
```

## 测试

- `swift test` — XCTest 单元测试 (Tests/BuddyCoreTests/)
- `swift test --filter Snapshot` — 视觉快照回归测试
- `tests/acceptance/run-all.sh` — Shell 验收测试
- CLI 自动测试: `buddy test --delay 2` — 遍历所有状态
- 手动测试 socket: `echo '{"event":"session_start","session_id":"test","timestamp":0,"cwd":"/tmp"}' | nc -U /tmp/claude-buddy.sock`

### 快照测试 (swift-snapshot-testing)

视觉回归测试位于 `Tests/BuddyCoreTests/SnapshotTests/`，基线图存储在 `__Snapshots__/` 子目录（已提交到 git）。

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

## Hook 插件

`plugin/` 目录是 Claude Code plugin，通过 marketplace 安装。Hook 脚本 (`plugin/scripts/buddy-hook.sh`) 在每个 Claude Code 事件时通过 Unix socket 发送 JSON 消息到 app。

**注意**: 修改 hook 脚本后需要同步到三个位置:
1. `plugin/scripts/buddy-hook.sh` (源码)
2. `hooks/buddy-hook.sh` (本地副本)
3. `~/.claude/plugins/cache/...` (plugin 缓存，用户通过 marketplace 更新)

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

## Autopilot 知识库

`.autopilot/` 目录存储 autopilot 模式产生的知识沉淀，必须提交到 git：

```
.autopilot/
├── index.md          # 知识索引（decisions + patterns 摘要）
├── decisions.md      # 架构决策记录（ADR）
├── patterns.md       # 编码模式与经验教训
├── worktree-links    # worktree 共享资源符号链接配置
├── doctor-report.md  # 工程健康诊断报告
├── project/          # 项目设计文档与任务 DAG
│   ├── dag.yaml      # 任务依赖图
│   ├── design.md     # 项目总体设计
│   └── tasks/        # 各任务详情
└── requirements/     # 各需求的状态、设计、脑暴、QA 报告
```

**重要**: 这些文件记录了开发过程中的架构决策、踩坑经验和模式沉淀，是项目知识资产的一部分，必须随代码一起提交到 git 管理。

## 任务管理

本项目的任务通过 ai-todo-cli 管理，任务空间为 `claude-code-buddy`（ID: `1f6cacb2-006f-4fc6-9126-bffb2e711743`）。

后续所有任务创建和进度更新都应同步到该任务空间：
- 创建任务时使用 `--parent_id 1f6cacb2-006f-4fc6-9126-bffb2e711743` 归属到此空间
- 完成工作后及时更新进度和日志

## 皮肤包商店 (Web)

独立 Next.js 项目，提供皮肤包上传、校验、审核、分发服务。

- **线上地址**: https://buddy.stringzhao.life
- **GitHub**: https://github.com/strzhao/claude-code-buddy-web
- **Vercel 项目**: claude-code-buddy-web (daniel21436-9089s-projects)
- **技术栈**: Next.js (App Router) + TypeScript + Tailwind + Upstash Redis + Vercel Blob

### API 端点

| 端点 | 说明 |
|------|------|
| `GET /api/skins` | 公开目录，返回 `RemoteSkinEntry[]`（桌面端直接消费） |
| `POST /api/upload` | 上传皮肤包 zip（multipart/form-data） |
| `GET /api/admin/skins?status=` | 管理员列表（pending/approved/rejected/all） |
| `POST /api/admin/skins/[id]/approve` | 批准皮肤包 |
| `POST /api/admin/skins/[id]/reject` | 拒绝皮肤包（body: `{reason}`) |
| `DELETE /api/admin/skins/[id]` | 删除皮肤包 |

### CLI 工具

```bash
cd claude-code-buddy-web/cli && npm run build
node dist/index.js upload <skin-directory> --server https://buddy.stringzhao.life
```

### 注意事项

- Admin 页面当前无认证（middleware.ts 占位），后续需接入用户系统
- 桌面端 `SkinGalleryViewController` 的 `catalogURL` 需改为指向 `https://buddy.stringzhao.life/api/skins`
