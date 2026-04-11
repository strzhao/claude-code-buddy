# Claude Code Buddy

macOS 桌面伴侣应用 —— 通过像素风猫咪在 Dock 上方实时反映 Claude Code 的工作状态。

每个活跃的 Claude Code 会话对应一只猫。猫咪空闲时打盹，思考时摇尾巴，写代码时来回奔跑。多个会话 = 多只猫共存。

## 快速开始

### 1. 构建

```bash
git clone <this-repo>
cd claude-code-buddy

# 开发模式运行
swift run

# 或打包为 .app
bash Scripts/bundle.sh
open ClaudeCodeBuddy.app
```

### 2. 配置 Claude Code Hooks

将以下内容添加到你的 Claude Code 设置文件中。

**方式 A：全局生效（推荐）**

编辑 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/claude-code-buddy/hooks/buddy-hook.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/claude-code-buddy/hooks/buddy-hook.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/claude-code-buddy/hooks/buddy-hook.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/claude-code-buddy/hooks/buddy-hook.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/claude-code-buddy/hooks/buddy-hook.sh",
            "timeout": 2
          }
        ]
      }
    ]
  }
}
```

> 将 `/绝对路径/` 替换为 `buddy-hook.sh` 的实际路径。

**方式 B：仅当前项目生效**

将上述内容写入项目目录下的 `.claude/settings.json` 或 `.claude/settings.local.json`。

### 3. 验证

```bash
# 确保 buddy app 正在运行，然后：
echo '{"session_id":"test","event":"thinking","tool":null,"timestamp":1}' | nc -U /tmp/claude-buddy.sock
```

Dock 上方应该出现一只猫。

## 猫咪状态

| 状态 | 触发事件 | 猫咪行为 |
|------|---------|---------|
| Idle | `Stop` / 等待用户输入 | 打盹、慵懒 |
| Thinking | `Notification` / Claude 生成回复中 | 蹲坐、摇尾巴 |
| Coding | `PreToolUse` / 执行工具调用 | 快速跑动 |

## 技术架构

```
Claude Code Hooks ──► buddy-hook.sh ──► Unix Socket ──► Buddy App ──► SpriteKit 猫咪
                      (Python3)         /tmp/claude-       (Swift)
                                        buddy.sock
```

- **Swift + SpriteKit** —— 透明无边框浮动窗口，紧贴 Dock 上方
- **Unix Domain Socket** —— 轻量级进程间通信
- **Python3** —— hook 脚本零外部依赖（macOS 内置）
- **物理引擎** —— 多只猫之间有碰撞，不会重叠

## 系统要求

- macOS 14+
- Swift 5.9+ / Xcode 15+
- Python3（macOS 内置）

## 运行测试

```bash
bash tests/acceptance/run-all.sh
```

## 项目结构

```
Sources/ClaudeCodeBuddy/
├── App/           入口 + AppDelegate
├── Window/        透明窗口 + Dock 位置检测
├── Scene/         SpriteKit 场景 + 猫咪精灵
├── Network/       Socket 服务器 + JSON 解析
├── Session/       会话生命周期管理
└── Assets/        像素猫精灵图（占位）

hooks/             Claude Code hook 脚本
Scripts/           构建和资源生成脚本
tests/             验收测试
```
