---
active: false
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: true
knowledge_extracted: "skipped"
task_dir: "/Users/lilei03/netease-ai/ClaudeCodeBuddy/claude-code-buddy/.worktrees/rocket-step1/.autopilot/requirements/20260418-修复问题"
session_id: 
started_at: "2026-04-18T05:33:23Z"
---

## 目标
修复问题

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

**目标**：修三个模式切换相关的视觉问题。

### 问题 1：rocket→cat 切换无退场动画
**现状**：`RocketEntity.exitScene` 只做 0.2s 淡出，火箭原地消失。
**修复**：所有火箭（无论当前状态：cruising / onpad / abort / landing）都做一次统一的 "原地起飞逃逸"：
- 先 `containerNode.removeAllActions()` + `node.removeAllActions()` + `padNode.removeAllActions()` 清掉当前状态残留动画
- 隐藏 padNode、OLM、boosterNode 的 scene 级 flame
- 对 containerNode 跑 `moveBy(x:0, y: +sceneHeight)` 0.7s 三次方缓入 + 并发 fadeOut 最后 0.25s
- 结束回调触发 removeFromParent + completion
- 如果 Starship：额外关掉 chopsticks、熄火 booster flame、手动 separateBooster 可跳过（反正整体升空 fade 会覆盖所有子节点）

### 问题 2：cat→rocket 边界贴图跳变
**现状**：`SessionManager.performHotSwitch` 在 `replaceAllEntities` 完成后才发 `entityModeChanged`。replaceAllEntities 的流程是 `exit old → addEntity new → completion`，所以新火箭先用旧边界（树）贴图spawn，事件发完后才切到 Mechazilla，观感就是"树突然变塔"。
**修复**：把 `entityModeChanged` 的发射时机挪到 `BuddyScene.replaceAllEntities` 里 `group.notify` 里、在 `addEntity` 循环**之前**发。这样：
- 旧 cat 走完退场动画（此时仍用树边界）
- 全部退出后 → 发 entityModeChanged → 边界切到 Mechazilla + OLM 装饰生效
- 新 rocket spawn（此时已经是新边界）
性能上没额外开销，只是发事件的时间点前移。
注意：`SessionManager.performHotSwitch` 自己也发了一次 entityModeChanged（在 replaceAllEntities completion 里），现在由 scene 先发，外层的就去掉避免重复。

### 问题 3：cat→rocket 后猫窝还在
**现状**：`CatTaskCompleteState` 把 bed 节点作为 scene 的子节点 `entity.containerNode.parent?.addChild(bed)`，命名 `bed_<sessionId>`。清理在 `willExit`。
Hot-switch 走 `replaceAllEntities` → `entity.exitScene(…) { entity.containerNode.removeFromParent() }` — 状态机的 willExit 不会被调用，bed 节点留在 scene 上。
**修复**：在 `BuddyScene.replaceAllEntities` 的 `group.notify` 里，addEntity 之前，扫一遍 scene children，凡是 name 以 `"bed_"` 开头的节点 `removeFromParent()`。把 `activeBedSlots` 字典也清空。

**文件影响**
| 文件 | 操作 | 说明 |
|---|---|---|
| `RocketEntity.swift` | 修改 `exitScene` | 统一起飞逃逸动画 |
| `BuddyScene.swift` | 修改 `replaceAllEntities` | 清 bed 节点 + 清 activeBedSlots + 发 entityModeChanged |
| `SessionManager.swift` | 修改 `performHotSwitch` | 去掉重复的 entityModeChanged 发射 |

**风险**
- entityModeChanged 订阅者除 BuddyScene 还有谁？→ grep 后决定是否真的能把外层发射去掉（可能 AppDelegate 也订阅）。保险起见：新增发射，保留旧的（幂等判断 previous==next 时不做 work）。
- 起飞逃逸动画会不会和 Starship 的 scene-level flame 节点冲突？→ exitScene 里先 `setBoosterIgnited(false)` 清掉 flame，再做起飞。

## 实现计划
- [ ] grep `entityModeChanged` 确认订阅者数量
- [ ] 改 `RocketEntity.exitScene` 做起飞逃逸
- [ ] 改 `BuddyScene.replaceAllEntities` 清 bed 节点 + 发 entityModeChanged
- [ ] 调整 `SessionManager.performHotSwitch` 避免重复发事件
- [ ] swift build + test
- [ ] 手动回归：cat↔rocket 来回切多次，观察动画 + bed 清理
- [ ] 提交

## 红队验收测试
(待 implement 阶段填充)

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [2026-04-18T05:33:23Z] autopilot 初始化，目标: 修复问题
