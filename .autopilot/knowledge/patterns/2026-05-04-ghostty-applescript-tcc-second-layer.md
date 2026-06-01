# Ghostty AppleScript `front window` 模式补充 — -1743 权限错误是独立于 terminal ID 缓存的第二层问题

<!-- tags: ghostty, applescript, terminal, tab, tcc, permission, nsscript -->
**Scenario**: 此前 pattern（2026-04-26）记录了 hook 脚本 CWD 匹配修复 terminal ID 缓存问题。但即使 terminal ID 缓存正确（6 个 session 的缓存 ID 与 Ghostty 实际 terminal ID 一一对应），点击猫咪仍无法切换 tab。根因是**第二层独立问题**：App 进程的 NSAppleScript 被 TCC 阻止（-1743），正确的 terminal ID 从未被用于实际 `focus` 命令。
**Lesson**: AppleScript 故障排除需区分两层：**数据层**（terminal ID 是否正确捕获/缓存）和**执行层**（AppleScript 是否有权限执行）。日志驱动的分层诊断（检查缓存值 + 检查 AppleScript error code + 对比 Terminal 内直接执行结果）快速定位到执行层。
**Evidence**: 用户报告拖拽松手后无法点击其他窗口。mouseUp 中添加 `window?.setInteractive(false)` + `hoveredSessionId = nil` 后修复。
