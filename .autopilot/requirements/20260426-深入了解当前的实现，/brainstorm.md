# Brainstorm: Ghostty Tab Focus Bug Fix

## 背景

用户在深度探索项目特性方向时发现了一个具体 bug：点击猫咪后 Ghostty 没有正确聚焦到对应的 tab。

## Q&A 记录

### Q: 最感兴趣的改进方向？
**A**: 用户反馈了一个具体 bug — Ghostty 多 tab 场景下点击猫咪总是跳到第一个 tab，而不是对应 session 所在的 tab。

### 根因分析

`buddy-hook.sh` 第 30-36 行使用 `selected tab of front window` 捕获 terminal ID：
- 多 tab 时这个 osascript 只会返回当前前台 tab 的 terminal ID
- 该 ID 被缓存后，所有 session 可能共享同一个错误的 terminal ID
- 点击猫咪时 `GhosttyAdapter.activateByTerminalId()` 找到错误 tab 并聚焦

### 修复方案

用 CWD 匹配替代 `front window` 盲取：
- hook 输入 JSON 包含 `cwd` 字段
- 遍历所有 Ghostty terminal，按 `working directory` 匹配找到正确的 terminal
- 保留 `front window` 作为 fallback（CWD 匹配失败时）

### 决策
先修复此 bug，后续再继续特性探索。
