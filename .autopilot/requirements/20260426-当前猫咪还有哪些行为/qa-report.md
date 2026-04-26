# QA 报告

## Wave 1: 静态验证
- ✅ `swift build` — 编译通过，无新增错误
- ✅ `swift test` — 427/427 测试全部通过（含新增 2 个朝向回归测试）
- ✅ `make lint` — 无新增 lint 违规

## Wave 2: E2E 验证
- ✅ idle→thinking — 状态正确切换
- ✅ thinking→toolUse — 状态正确切换
- ✅ toolUse→permissionRequest — 红色 tint + alert overlay 正确显示
- ✅ permissionRequest→toolUse（click 后）— badge/alert 正确清理
- ✅ 快速连续切换 (thinking→tool_start→idle) — 正确到达最终状态 idle
- ✅ toolUse 移动 — 猫咪正常行走，无阻塞
- ✅ taskComplete — 正确请求床位并进入睡眠
- ✅ taskComplete→thinking — 正确从床上唤醒
- ✅ 3 只猫同时 toolUse — 位置持续变化，无穿越阻塞
- ✅ 朝向回归测试 — xScale 在走路时为 ±1.0（snapped）
