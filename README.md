# Claude Code Buddy

macOS 桌面伴侣 —— Dock 上方的像素猫咪，实时反映 Claude Code 的工作状态。

每个 Claude Code 会话对应一只猫。空闲时打盹，思考时摇尾巴，写代码时来回奔跑。多个会话 = 多只猫共存。

## 安装（2 步）

### 第 1 步：下载 App

**方式 A：Homebrew（推荐）**

```bash
brew tap strzhao/claude-code-buddy
brew install claude-code-buddy
```

**方式 B：手动下载**

前往 [Releases](../../releases) 页面，下载最新的 `ClaudeCodeBuddy-vX.Y.Z.zip`。

解压后将 `ClaudeCodeBuddy.app` 拖入 `Applications` 文件夹，双击打开。

> 首次打开时 macOS 会提示"无法验证开发者"，请右键点击 app → 选择「打开」即可。

### 第 2 步：安装 Hooks 插件

在 Claude Code 中依次运行：

```
/plugin marketplace add strzhao/claude-code-buddy
/plugin install claude-code-buddy-hooks
/reload-plugins
```

完成！现在正常使用 Claude Code，猫咪就会自动出现在 Dock 上方。

## 猫咪状态

| 状态 | 触发 | 猫咪行为 |
|------|------|---------|
| Idle | 等待用户输入 | 打盹、慵懒 |
| Thinking | Claude 正在思考 | 蹲坐、摇尾巴 |
| Coding | 执行工具调用 | 快速跑动 |

## 形态切换（New in v0.7.0）

ClaudeCodeBuddy 支持两种形态，随时热切换：

- 🐱 **Cat**（默认）— 像素猫咪，带食物、睡床、惊吓等丰富交互。
- 🚀 **Rocket** — 像素火箭，状态可视化为点火/巡航/告警/回收/升空。

切换方式（立即生效，无需重启）：

**状态栏**：点击菜单栏 Buddy 图标 → 顶部 `🐱 Cat / 🚀 Rocket` 分段控件。

**命令行**：

```bash
buddy morph rocket     # 切换到火箭
buddy morph cat        # 切回猫
buddy morph            # 查询当前形态
```

切换过程中会话身份、颜色、当前状态全部保留。

## 技术架构

```
Claude Code ──► Plugin Hooks ──► Unix Socket ──► Buddy App ──► SpriteKit 猫咪
                (自动注册)       /tmp/claude-      (Swift)
                                buddy.sock
```

- **Swift + SpriteKit** —— 透明浮动窗口，紧贴 Dock 上方
- **物理引擎** —— 多只猫之间有碰撞，不会重叠
- **Claude Code Plugin** —— hooks 自动注册，零手动配置

## 系统要求

- macOS 14+
- Claude Code CLI

## 开发者指南

<details>
<summary>从源码构建</summary>

```bash
git clone https://github.com/strzhao/claude-code-buddy.git
cd claude-code-buddy

# 开发模式
swift run

# 打包 .app
bash Scripts/bundle.sh
open ClaudeCodeBuddy.app
```

</details>

<details>
<summary>手动配置 Hooks（不用插件）</summary>

编辑 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "SessionStart":  [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}],
    "Notification":  [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}],
    "PreToolUse":    [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}],
    "PostToolUse":   [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}],
    "Stop":          [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}],
    "SessionEnd":    [{"matcher":"","hooks":[{"type":"command","command":"/路径/hooks/buddy-hook.sh","timeout":2}]}]
  }
}
```

</details>

<details>
<summary>运行测试</summary>

```bash
bash tests/acceptance/run-all.sh
```

</details>

<details>
<summary>发布新版本</summary>

```bash
git tag v1.0.0
git push origin v1.0.0
# GitHub Actions 自动构建并创建 Release
```

</details>

## 项目结构

```
Sources/ClaudeCodeBuddy/     Swift 源码（App/Window/Scene/Network/Session）
plugin/                      Claude Code 插件（hooks 自动注册）
hooks/                       独立 hook 脚本（手动配置用）
Scripts/                     构建和资源生成脚本
tests/                       验收测试
.github/workflows/           CI/CD 自动发布
```

## Credits

- Cat sprites: "2D Pixel Art Cat Sprites" from itch.io (free for commercial/non-commercial use)
