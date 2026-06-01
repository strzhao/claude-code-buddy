# Ghostty AppleScript `front window` 在多 tab 时捕获错误的 terminal ID

<!-- tags: ghostty, applescript, terminal, tab, hook, cwd -->
**Scenario**: hook 脚本用 `selected tab of front window` 捕获 Ghostty terminal ID 并缓存。多 tab 场景下，所有 session 可能都缓存了同一个（错误的）tab 的 ID，导致点击猫咪总是跳到第一个 tab。
**Lesson**: `front window` / `selected tab` 只返回当前用户聚焦的 tab，不是 Claude Code 运行所在的 tab。正确做法是遍历 `terminals of every tab of every window` 按 `working directory` 匹配（与 tab title 注入使用相同模式）。保留 `front window` 作为 CWD 匹配失败时的 fallback。同 CWD 多 tab 时匹配第一个，可接受但非完美。
**Evidence**: 3 个 Ghostty tab 分别运行不同 CWD 的 session，修复前全部缓存了 tab 1 的 terminal ID；修复后 CWD 匹配分别拿到了 3 个不同的正确 terminal ID。
