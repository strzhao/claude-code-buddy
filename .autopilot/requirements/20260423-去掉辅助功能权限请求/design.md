# 设计文档

**目标**：移除启动时的辅助功能权限请求弹窗

**技术方案**：删除 `AppDelegate.swift` 中的 `AXIsProcessTrustedWithOptions` 调用。`DockIconBoundsProvider` 的 AX 查询代码保留，失败时自动回退到启发式估算。

**文件影响**：
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` — 删除 AXIsProcessTrustedWithOptions 调用

**风险评估**：极低。Dock 定位已有回退机制。
