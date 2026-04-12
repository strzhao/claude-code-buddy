---
active: true
phase: "done"
gate: ""
iteration: 2
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "true"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-猫咪的移动方向和头的"
session_id: 18909073-0d4e-4666-9a0e-3d0c1a2d1292
started_at: "2026-04-12T15:17:31Z"
---

## 目标
猫咪的移动方向和头的朝向经常错，设计一个方案，在底层彻底避免这个问题，真的做不到也应该通过测试检查可以发现

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
在底层彻底消除猫咪朝向不一致问题：通过集中化方向控制 API + `didSet` 自动同步 + 修复已知 bug + 全面测试覆盖。

### 根因分析
- **Bug 1 — 静止转向**：`MovementComponent.doRandomWalkStep()` 在判断移动距离之前就设置了方向，导致猫不移动但方向已变
- **Bug 2 — tabName 标签镜像**：`applyFacingDirection()` 遗漏了 `tabNameNode` 和 `tabNameShadowNode` 的 xScale 补偿
- **Bug 3 — 方向逻辑散落重复**：5 处内联 if/else + applyFacingDirection 调用

### 技术方案
1. `facingRight` 加 `didSet { applyFacingDirection() }` 自动同步
2. 新增 `face(towardX:)` 和 `face(right:)` 统一 API
3. 替换所有 5 处散落调用为统一 API
4. 修复静止转向 bug（face 调用移到 distance 检查之后）
5. 修复 tabName 标签补偿
6. 保留 `switchState()` 和 `enterScene()` 中的显式 `applyFacingDirection()` 作为安全网

## 实现计划

- [x] 1. CatSprite: `facingRight` 添加 `didSet`，保留 switchState/enterScene 中的显式调用
- [x] 2. CatSprite: 添加 `face(towardX:)` 和 `face(right:)` 方法
- [x] 3. CatSprite: `applyFacingDirection()` 补充 tabNameNode/tabNameShadowNode 补偿
- [x] 4. MovementComponent: 替换 4 处方向逻辑 + 修复静止转向 bug
- [x] 5. InteractionComponent: 替换 1 处方向逻辑
- [x] 6. 新建 FacingDirectionTests.swift 单元测试

## 红队验收测试

文件：`Tests/BuddyCoreTests/FacingDirectionTests.swift`（13 个测试方法）

覆盖验收场景：
- S-01/S-02: face(towardX:) 左右方向
- S-03: 阈值内不改方向
- S-04: walkMinDistance 与 facingDirectionThreshold 关系断言
- S-05/S-06: applyFacingDirection 补偿所有 label 节点
- S-06 (fright): 受惊逃跑方向
- S-07: walkToFood 方向
- S-08: exitScene 方向
- S-09: delta=0 保持方向
- S-10: didSet 自动触发
- switchState 方向保持

## QA 报告

### Wave 1: 构建 + 测试
- ✅ `make build` 通过（0.39s，无警告）
- ✅ `make test` 通过（157 个测试，0 失败，包含 13 个新增 FacingDirectionTests）

### Wave 1.5: 静态审计
- ✅ `facingRight =` 赋值仅在 `face(towardX:)` 和 `face(right:)` 内部（3 处），无遗漏
- ✅ `applyFacingDirection()` 调用仅在 didSet（自动）、switchState（安全网）、enterScene（安全网）3 处，无冗余
- ✅ 所有 label 节点（labelNode、shadowLabelNode、tabNameNode、tabNameShadowNode）均在 applyFacingDirection 中补偿

### 结论：全部 ✅

## 变更日志
- [2026-04-12T15:17:31Z] autopilot 初始化，目标: 猫咪的移动方向和头的朝向经常错，设计一个方案，在底层彻底避免这个问题，真的做不到也应该通过测试检查可以发现
- [2026-04-12T15:25:00Z] design 阶段完成：方案通过 Plan Reviewer 审查 + 用户审批，进入 implement 阶段
- [2026-04-13T00:03:00Z] implement 阶段完成：CatSprite API + MovementComponent + InteractionComponent 改动完成，157 个测试全部通过，进入 qa 阶段
- [2026-04-13T00:06:00Z] qa 阶段完成：构建通过 + 157 测试全通 + 静态审计全通，等待用户审批
- [2026-04-13T00:15:00Z] E2E 测试通过：45 场景全 PASS（事件通路、状态机、缺口补全、边界异常），用户审批通过，进入 merge 阶段
- [2026-04-13T00:20:00Z] merge 完成：2 个 commit (3dd04fc fix + 04750c8 test)，phase: done
- [2026-04-13T00:22:00Z] 知识提取完成：新增 .autopilot/patterns.md（didSet+统一API模式）+ .autopilot/decisions.md（朝向系统集中化决策）
