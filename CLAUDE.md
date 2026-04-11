# Claude Code Buddy

macOS 桌面应用：Dock 上方的像素猫咪，实时反映 Claude Code 工作状态。

## 架构

```
Sources/ClaudeCodeBuddy/
├── App/            # AppDelegate, main.swift 入口
├── Scene/          # SpriteKit 场景: BuddyScene, CatSprite, TooltipNode
├── Session/        # 会话管理: SessionManager, SessionInfo, SessionColor
├── Network/        # IPC: SocketServer (Unix domain socket), HookMessage
├── Terminal/       # 终端适配: GhosttyAdapter (AppleScript 控制)
├── Window/         # 窗口: BuddyWindow, DockTracker, MouseTracker
├── MenuBar/        # 状态栏弹窗: SessionPopoverController
├── Assets/Sprites/ # 48x48 像素猫咪精灵图
└── Resources/      # Info.plist
```

**数据流**: Claude Code Hook → buddy-hook.sh → Unix Socket → SocketServer → SessionManager → BuddyScene/CatSprite

**猫咪状态机**: idle(sleep/breathe/blink/clean) → thinking(curious paw) → toolUse(random walk) → permissionRequest(alert+badge)

## 开发

```bash
make build          # 编译 debug
make run            # 编译并启动
make test           # 运行单元测试
make lint           # SwiftLint 检查
make clean          # 清理构建产物
make release        # 编译 release
make bundle         # 打包 .app
```

## 测试

- `swift test` — XCTest 单元测试 (Tests/BuddyCoreTests/)
- `tests/acceptance/run-all.sh` — Shell 验收测试
- 手动测试 socket: `echo '{"event":"session_start","session_id":"test","timestamp":0,"cwd":"/tmp"}' | nc -U /tmp/claude-buddy.sock`

## Hook 插件

`plugin/` 目录是 Claude Code plugin，通过 marketplace 安装。Hook 脚本 (`plugin/scripts/buddy-hook.sh`) 在每个 Claude Code 事件时通过 Unix socket 发送 JSON 消息到 app。

**注意**: 修改 hook 脚本后需要同步到三个位置:
1. `plugin/scripts/buddy-hook.sh` (源码)
2. `hooks/buddy-hook.sh` (本地副本)
3. `~/.claude/plugins/cache/...` (plugin 缓存，用户通过 marketplace 更新)

## Package 结构

- `BuddyCore` (library target) — 所有业务逻辑
- `ClaudeCodeBuddy` (executable target) — 仅 main.swift 入口
- `BuddyCoreTests` (test target) — XCTest 单元测试

## 任务管理

本项目的任务通过 ai-todo-cli 管理，任务空间为 `claude-code-buddy`（ID: `1f6cacb2-006f-4fc6-9126-bffb2e711743`）。

后续所有任务创建和进度更新都应同步到该任务空间：
- 创建任务时使用 `--parent_id 1f6cacb2-006f-4fc6-9126-bffb2e711743` 归属到此空间
- 完成工作后及时更新进度和日志
