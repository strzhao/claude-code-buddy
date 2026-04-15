---
active: false
phase: "done"
gate: ""
iteration: 3
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260416-看到了，但是要修正-2"
session_id: 7b5d6e92-a323-4e41-9d98-edf433f332c3
started_at: "2026-04-15T17:14:53Z"
---

## 目标
看到了，但是要修正 2 个 点 1. 猫屋要一起变大，当前猫完全把猫屋挡住了 2. debug 模式下常驻的文字太高，导致被截断了

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档
### Fix 1: 猫屋放大 2x
- bedRenderSize: 24×14 → 48×28, slotSpacing: -48 → -56, firstSlotOffset: -52 → -60
- bed.position y: 7 → 14（CatTaskCompleteState.swift）
- 无需重制精灵图（nearest-neighbor 过滤）

### Fix 2: 降低 debug tab name 标签
- tabLabelYOffset: 46 → 18（标签底部 Y=66, 顶部 Y=78, 在 80px 窗口内）
- tabLabelShadowYOffset: 45 → 17

## 实现计划
- [x] 修改 CatConstants.swift：bedRenderSize、slotSpacing、firstSlotOffset
- [x] 修改 CatConstants.swift：tabLabelYOffset、tabLabelShadowYOffset
- [x] 修改 CatTaskCompleteState.swift：bed.position Y 值
- [x] make build 验证编译
- [x] make test 验证测试（210 原有 + 10 新增 = 220 全通过）
- [x] 手动视觉验证（app 已启动，debug 猫可见）

## 红队验收测试
- 文件: Tests/BuddyCoreTests/BedAndLabelVisualTests.swift (10 个测试)
- 猫屋常量: bedRenderSize 48×28, slotSpacing -56, firstSlotOffset -60
- 标签位置: tabLabelYOffset 18, tabLabelShadowYOffset 17
- 窗口可见性: groundY+offset+fontSize ≤ 80
- 猫屋与猫尺寸匹配

## QA 报告

### 轮次 1 (2026-04-16) — ✅ 全部通过

**变更分析**: 2 文件 6 行（CatConstants.swift 5 常量 + CatTaskCompleteState.swift 1 行位置）

**Wave 1 — 命令执行**
- Tier 0 红队验收: ✅ 10/10 tests passed (0.003s)
- Tier 1 Build: ✅ Build complete (0.41s)
- Tier 1 Tests: ✅ 220/220 tests passed (38.8s)
- Tier 1 Lint: ✅ 0 violations in 49 files

**Wave 1.5 — 真实场景验证**
- 场景 1: debug 标签可见性
  - 执行: `buddy session start --id debug-visual --cwd /tmp/myproject` → Session started
  - 输出: Active sessions 显示 debug-visual, label=myproject
- 场景 2: 猫屋 task_complete 触发
  - 执行: `buddy emit task_complete --id debug-visual` → Event sent
  - 输出: task_complete 事件正常处理

**Wave 2 — AI 审查**
- Tier 2a 设计符合性: ✅ PASS — 7/7 设计要求全部符合，红队测试完整覆盖
- Tier 2b 代码质量: ✅ 0 Critical, 1 Important (bed.position.y 建议提取为常量), 1 Minor

**改进建议**:
- [Important] CatTaskCompleteState.swift:55 的 `y: 14` 建议提取为 CatConstants.TaskComplete.bedYOffset

## 变更日志
- [2026-04-15T17:14:53Z] autopilot 初始化
- [2026-04-16T01:28:00Z] design 阶段完成，方案通过 plan-reviewer 审查
- [2026-04-16T01:28:30Z] implement 完成：CatConstants.swift 5 个常量 + CatTaskCompleteState.swift 1 行位置
- [2026-04-16T01:29:00Z] 红队验收测试生成：10 个测试全部通过（220/220）
- [2026-04-16T01:35:00Z] QA 完成：全部 ✅（Tier 0/1/1.5/2a/2b 通过），1 Important 改进建议
