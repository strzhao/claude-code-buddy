---
active: true
phase: "done"
gate: ""
iteration: 8
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "true"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260418-优化猫咪交互-1.-权限"
session_id: 9b1a2bdc-3a35-4053-8ed0-4ffc89087791
started_at: "2026-04-18T11:47:18Z"
---

## 目标
优化猫咪交互 1. 权限请求后展示的感叹号一直都存在，当前缺乏消失时机，当用户点击猫咪后就可以消失了 2. 猫屋的距离太近了，导致猫咪头顶的文字会重叠，看不清楚

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
优化猫咪交互体验：点击消除持久徽章 + 增大猫屋间距防止标签重叠

### 技术方案

**Fix 1: 点击消除持久徽章**
- `BuddyScene` 新增 `removePersistentBadge(for sessionId: String)` 方法
- `AppDelegate.onClick` 闭包中调用该方法

**Fix 2: 增大猫屋间距**
- `CatConstants.TaskComplete.slotSpacing` 从 `-56` 改为 `-80`

### 文件影响范围
| 文件 | 操作 | 说明 |
|------|------|------|
| `BuddyScene.swift` | 新增方法 | `removePersistentBadge(for:)` |
| `AppDelegate.swift` | 修改 | onClick 闭包添加 badge 移除调用 |
| `CatConstants.swift` | 修改 | `slotSpacing` -56 → -80 |

## 实现计划

- [x] `CatConstants.swift`: 修改 `slotSpacing` 为 `-80`
- [x] `BuddyScene.swift`: 新增 `removePersistentBadge(for sessionId: String)` 公开方法
- [x] `AppDelegate.swift`: 在 `onClick` 闭包中调用 `buddyScene.removePersistentBadge(for: sessionId)`

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1: 静态验证
- ✅ `make build` — 编译成功
- ✅ `make test` — 366 tests, 0 failures
- ✅ `make lint` — 0 violations

### Wave 1.5: 真实测试场景（3/3 已执行）
- ✅ 场景 1: 徽章点击消除 — 点击猫咪后 "!" 徽章立即消失
- ✅ 场景 2: 徽章隔离 — 点击 A 猫，A 徽章消失，B 保持不变
- ✅ 场景 3: 4 只猫满床位标签可读 — slotSpacing 调整为 -100 后标签无重叠（-80 仍有重叠，用户反馈后增大至 -100）

**结论: 全部通过**

## 变更日志
- [2026-04-18T11:47:18Z] autopilot 初始化，目标: 优化猫咪交互 1. 权限请求后展示的感叹号一直都存在，当前缺乏消失时机，当用户点击猫咪后就可以消失了 2. 猫屋的距离太近了，导致猫咪头顶的文字会重叠，看不清楚
- [2026-04-18T11:50:00Z] design 方案通过审批，进入 implement 阶段
- [2026-04-18T12:02:00Z] implement 完成：3 个文件已修改，366 测试全通过，lint 0 violations。进入 qa 阶段
- [2026-04-18T12:43:00Z] qa 全部通过（3/3 场景 + 静态验证）。slotSpacing 从 -80 调整为 -100（用户反馈 -80 仍有重叠）。进入 merge 阶段
