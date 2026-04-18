---
active: true
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
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/quiet-enchanting-stonebraker/.autopilot/requirements/20260418-优化猫咪的状态，方便"
session_id: 332ab600-b782-4cae-a34b-3da47682c688
started_at: "2026-04-17T16:45:12Z"
---

## 目标
优化猫咪的状态，方便人更好的理解 claude code 的真实状态 1. request permisson 状态保持时间要更久，且及时不保持了，猫旁边任然需要有感叹号，这样无论人什么时候过来看都知道有状态需要确认 2. 猫咪在 stop 的状态下，在猫窝上睡觉时，猫头顶的文字要常驻显示，方便人知道是哪个任务完成了

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
让猫咪状态更持久、更易识别，用户随时回到屏幕都能了解 Claude Code 的真实状态。

### Feature 1: 持久化 Permission 感叹号徽章
在 `LabelComponent` 中新增独立的「持久徽章」节点（`persistentBadgeNode`），与现有的 `alertOverlayNode`（动画徽章）分开管理。当 permission request 状态退出时，动画徽章消失，但持久徽章保留。持久徽章：小号红色圆(radius 7) + "!" + 慢呼吸脉冲(1.5s 周期)，位于猫咪右上角固定位置。仅在猫被移除或重新进入 permissionRequest 时清除。

### Feature 2: TaskComplete 状态常驻 Tab Name
猫走到床上开始睡觉后，显示 tabName 标签。在 `startSleepLoop()` 中调用 `showTabName()`。

## 实现计划
- [x] 1. CatConstants.swift — 添加 PersistentBadge 常量
- [x] 2. LabelComponent.swift — 添加 persistentBadgeNode + showTabName
- [x] 3. CatSprite.swift — 转发属性 + applyFacingDirection + switchState 不清理持久徽章
- [x] 4. CatPermissionRequestState.swift — didEnter 清旧徽章 + willExit 创建持久徽章
- [x] 5. CatTaskCompleteState.swift — startSleepLoop 显示 tabName
- [x] 6. 单元测试 — 8 个新测试全部通过

## 红队验收测试

### T1: 持久徽章在 permission 退出后存在
```
buddy session start --id debug-A --cwd ~/tmp
buddy emit permission_request --id debug-A --tool Read --desc "Reading file"
sleep 2
buddy emit thinking --id debug-A
→ 预期: 猫恢复正常颜色，右上角有小红色 "!" 慢呼吸脉冲
```

### T2: 持久徽章跨状态存活
```
buddy emit tool_start --id debug-A --tool Read --desc "Reading file"
sleep 2
buddy emit tool_end --id debug-A
→ 预期: "!" 仍然存在
```

### T3: 持久徽章在 session end 时清除
```
buddy session end --id debug-A
→ 预期: 猫退场，"!" 随之消失
```

### T4: 重入 permission 清除旧持久徽章
```
buddy session start --id debug-B --cwd ~/tmp
buddy emit permission_request --id debug-B --tool Read --desc "First"
buddy emit thinking --id debug-B
→ 持久 "!" 出现
buddy emit permission_request --id debug-B --tool Write --desc "Second"
→ 预期: 进入红色闪烁状态，旧持久 "!" 消失，动画 "!" 取代
buddy emit idle --id debug-B
→ 预期: 新的持久 "!" 出现
buddy session end --id debug-B
```

### T5: TaskComplete 床上显示 tab name
```
buddy session start --id debug-C --cwd ~/myproject
buddy emit thinking --id debug-C
sleep 2
buddy emit task_complete --id debug-C
→ 预期: 猫走到右侧猫窝，到达后头顶显示 tab name 文字
buddy session end --id debug-C
```

## QA 报告

### Wave 1 — 静态验证
- ✅ `make build`: 编译成功 (0.41s)
- ✅ `make lint`: 0 violations, 0 serious in 58 files
- ✅ `make test`: 342 tests, 0 failures (8 新增 + 334 原有)

### Wave 1.5 — 代码质量审查
- ✅ LabelComponent: `addPersistentBadge/removePersistentBadge` 与现有 `addAlertOverlay/removeAlertOverlay` 结构对称
- ✅ CatSprite: 转发方法 + `applyFacingDirection` counter-scale 符合既有模式
- ✅ CatPermissionRequestState: `didEnter` 清旧 + `willExit` 创建新，生命周期完整
- ✅ CatTaskCompleteState: `showTabName()` 在 `startSleepLoop()` 末尾调用，fright `resume()` 会重新调用
- ✅ 常量引用统一，无硬编码魔法数字

### Wave 2 — 验收场景（CLI 驱动）
- ✅ T1: `permission_request → thinking` 事件流正常
- ✅ T2: `tool_start` 跨状态事件正常
- ✅ T3: `session end` 清理正常
- ✅ T4: 重入 permission 事件流正常
- ✅ T5: `task_complete` 走床事件流正常
- ⚠️ 视觉效果需人工确认（无截屏能力）

### 结论
全部静态检查和自动化测试通过。CLI 验收测试事件流无错误。视觉效果（持久 "!" 呼吸脉冲、床上 tab name）需用户启动 app 后视觉确认。

## 变更日志
- [2026-04-18T11:17:21Z] 用户批准验收，进入合并阶段
- [2026-04-17T16:45:12Z] autopilot 初始化，目标: 优化猫咪的状态，方便人更好的理解 claude code 的真实状态 1. request permisson 状态保持时间要更久，且及时不保持了，猫旁边任然需要有感叹号，这样无论人什么时候过来看都知道有状态需要确认 2. 猫咪在 stop 的状态下，在猫窝上睡觉时，猫头顶的文字要常驻显示，方便人知道是哪个任务完成了
- [2026-04-18T08:46:00Z] 设计方案通过审批（Plan Reviewer PASS + 用户批准），进入 implement 阶段
- [2026-04-18T09:03:00Z] 实现完成: 6 个文件修改 + 1 个新测试文件，编译通过，342 测试全过，lint 0 violations。进入 QA 阶段
- [2026-04-18T09:07:00Z] QA 通过: Wave 1 静态验证 ✅ + Wave 1.5 代码审查 ✅ + Wave 2 CLI 验收 ✅。等待用户审批
- [2026-04-18T11:18:00Z] merge 阶段: 代码提交 cc775eb + 产出物归档完成，phase: "done"
