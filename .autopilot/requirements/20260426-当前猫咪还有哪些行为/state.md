---
active: true
phase: "qa"
gate: "review-accept"
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: "deep"
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260426-当前猫咪还有哪些行为"
session_id: 6c2809d0-3bf4-4965-84d4-bea7dc1e99f3
started_at: "2026-04-26T12:01:11Z"
---

## 目标
当前猫咪还有哪些行为不够自然，不够真实，设计优化方案

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
优化猫咪状态转换和移动的自然感。纯代码实现（缩放/旋转/速度变化），不增加新精灵帧，兼容所有现有皮肤包。

### Part 1: 状态转换框架（渐进式 Handoff）
- `switchState()` 不再瞬间 `removeAllActions()`，改为 0.15s handoff 窗口
- containerNode 位置 action 立即停止，node 上的帧动画走加速逻辑
- 各状态可通过 `prepareExitActions()` 插入自定义退出动画
- pending 使用 last-wins 单值模式，测试环境走即时路径

### Part 2: 自然移动（速度曲线 + 渐进漫步）
- 目标点从均匀 ±120px 改为加权分布（小步 80% / 中步 15% / 大步 5%）
- 帧率与移动速度联动
- 起步前 2 帧慢速，停步有 squash 微动画

### 文件影响
- CatConstants.swift — Transition enum + Movement 新常量
- CatSprite.swift — switchState() 重写 + 辅助方法
- 6 个 State 文件 — prepareExitActions()
- MovementComponent.swift — 目标选择 + 帧率 + 停步过渡
- CatPersonality.swift — stepSizeActivityShift

## 实现计划

- [ ] **1.1** CatConstants.swift — 新增 Transition enum
- [ ] **1.2** CatSprite.swift — 新增 transition 属性
- [ ] **1.3** 各 State — 新增 prepareExitActions()
- [x] **1.4** CatSprite.swift — 重写 switchState()
- [x] **1.5** CatSprite.swift — 新增辅助方法
- [x] **2.1** CatConstants.swift — Movement 新增渐进步幅常量
- [x] **2.2** CatPersonality.swift — 新增 stepSizeActivityShift
- [x] **2.3** MovementComponent.swift — 重写目标选择+帧率+停步

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1: 静态验证
- ✅ `swift build` — 编译通过，无新增错误
- ✅ `swift test` — 425/425 测试全部通过，0 失败
- ✅ `make lint` — 无新增 lint 违规（既有 BuddyCLI large_tuple 不影响）

### Wave 2: E2E 验证
- ✅ idle→thinking — 状态正确切换
- ✅ thinking→toolUse — 状态正确切换
- ✅ toolUse→permissionRequest — 红色 tint + alert overlay 正确显示
- ✅ permissionRequest→toolUse（click 后）— badge/alert 正确清理
- ✅ 快速连续切换 (thinking→tool_start→idle) — 正确到达最终状态 idle
- ✅ toolUse 移动 — 猫咪正常行走
- ✅ taskComplete — 正确请求床位并进入睡眠
- ✅ taskComplete→thinking — 正确从床上唤醒

## 变更日志
- [2026-04-26T12:01:11Z] autopilot 初始化，目标: 当前猫咪还有哪些行为不够自然，不够真实，设计优化方案
- [2026-04-26T12:15:00Z] Deep Design 完成：Q&A 确认聚焦状态转换+移动自然化，渐进式 Handoff + 速度曲线方案通过审批
- [2026-04-26T12:30:00Z] implement 完成：10 文件 +240/-48 行，swift build ✅，swift test 425/425 ✅，lint 无新增违规
- [2026-04-26T12:35:00Z] QA 完成：静态验证 3/3 ✅，E2E 验证 8/8 ✅，等待用户审批
