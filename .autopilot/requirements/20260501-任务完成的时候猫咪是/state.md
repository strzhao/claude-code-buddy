---
active: true
phase: "merge"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace/claude-code-buddy/.autopilot/requirements/20260501-任务完成的时候猫咪是"
session_id: 429679a5-4165-4614-aae0-ca45743f07a9
started_at: "2026-05-01T15:27:41Z"
---

## 目标
任务完成的时候猫咪是倒着走的，解决这个问题

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 根因

`CatTaskCompleteState.walkToBed()` 调用 `entity.face(towardX: targetX)` 后，若朝向改变则触发 `smoothTurn`（0.2s 渐进 xScale 动画），但 walk 动画和位移立即启动。0.2s 窗口内 `node.xScale` 处于过渡中间值，而 `containerNode` 已向目标移动，导致视觉上倒着走。

这是已知模式的第三次复发，前两次修复：
- `MovementComponent.doRandomWalkStep()` — 已有 smoothTurn guard + snap
- `MovementComponent.walkBackIntoBounds()` — 已有 smoothTurn guard + snap

### 修复方案

在 `walkToBed()` 的 `entity.face(towardX:)` 后、walk 动画前，加入 smoothTurn guard + snap（与其他 walk 方法一致）：

```swift
if entity.node.action(forKey: "smoothTurn") != nil {
    entity.node.removeAction(forKey: "smoothTurn")
    entity.applyFacingDirection()
}
```

### 修改文件

| 文件 | 改动 |
|------|------|
| `Sources/ClaudeCodeBuddy/Entity/Cat/States/CatTaskCompleteState.swift:101` | 在 `face()` 后添加 4 行 smoothTurn guard + snap |

## 实现计划

- [x] 在 `CatTaskCompleteState.walkToBed()` 第 101 行后添加 smoothTurn guard + snap（4 行）
- [x] 编译验证通过
- [x] 全部单元测试通过（0 失败）

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1 — 命令执行

| Tier | 检查项 | 结果 | 证据 |
|------|--------|------|------|
| 1 | 构建 | ✅ | Build complete! (0.24s) |
| 1 | Lint | ✅ | 0 violations in 65 files |
| 1 | 单元测试 | ✅ | 全部测试套件通过，0 失败 |

### Wave 1.5 — E2E 验证

**场景 1：任务完成时猫背对床位**
- 执行: `buddy session start --id debug-fix` → `buddy emit thinking` → `buddy emit tool_start` → `buddy emit task_complete` → `buddy inspect`
- 输出: `facing_right: false` → `facing_right: true`（正确翻转），`x: 643 → 798`（朝床位方向移动）
- 结果: ✅ 猫咪面向正确，没有倒着走

### 结果判定

场景计数: 1/1 ✅ | 格式检查: 执行+输出完整 ✅

全部 ✅ — 无失败项

## 变更日志
- [2026-05-01T15:39:43Z] 用户批准验收，进入合并阶段
- [2026-05-01T15:27:41Z] autopilot 初始化，目标: 任务完成的时候猫咪是倒着走的，解决这个问题
- [2026-05-01T15:35:00Z] design 完成：根因确认为 walkToBed() 遗漏 smoothTurn guard + snap（第三次复发）
- [2026-05-01T15:36:00Z] implement 完成：在 CatTaskCompleteState.swift:101 后添加 4 行修复
- [2026-05-01T15:37:00Z] 编译通过 + 全部单元测试 0 失败
- [2026-05-01T15:39:00Z] QA 完成：构建 ✅ / Lint ✅ / 单测 ✅ / E2E ✅ → gate: review-accept
