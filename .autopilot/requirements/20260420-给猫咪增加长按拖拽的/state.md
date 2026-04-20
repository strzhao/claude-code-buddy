---
active: true
phase: "done"
gate: "review-accept"
iteration: 2
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: "deep"
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "true"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/jolly-sniffing-mitten/.autopilot/requirements/20260420-给猫咪增加长按拖拽的"
session_id: 0b626498-16b3-496b-900f-767b7f161524
started_at: "2026-04-20T15:39:26Z"
---

## 目标
给猫咪增加长按拖拽的功能 1. 长按后可以拖拽到另外一个地方 2. 皮肤包设置了多一个被拖拽过程中的状态配置，历史的做好降级 3. 猫咪下落是做好设计 整体要自然有趣且符合逻辑

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
猫咪支持长按 0.3s 触发拖拽，拖拽过程中播放专属 grabbed 动画（旧皮肤降级为 scared），松手后自由落体+弹跳着陆，最终恢复拖拽前的业务状态。

### 技术方案
- **DragComponent**（新建）：核心拖拽组件，管理 isDragging/isLanding/isOccupied 状态，startDrag/updatePosition/endDrag/playFallAndBounce
- **MouseTracker 扩展**：localMonitor 添加 leftMouseDragged/leftMouseUp，0.3s 长按检测
- **CatSprite 扩展**：dragComponent 属性、switchState 拖拽保护、isDragOccupied
- **BuddyScene 连接**：draggedCat 管理、update() 豁免、session_end 缓冲
- **AppDelegate 窗口管理**：拖拽时扩展窗口到全屏高度，落地后恢复
- **皮肤包降级**：grabbed → scared 自动降级
- **落体物理**：自由落体 + 1-2 次弹跳（dropGravity=1200, restitution=0.35）

## 实现计划

- [x] T1: CatConstants.Drag 常量区
- [x] T2: DragComponent 核心组件
- [x] T3: CatSprite 集成
- [x] T4: MouseTracker 扩展
- [x] T5: BuddyScene 连接
- [x] T6: AppDelegate 窗口管理
- [x] T7: 手动测试验证

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1: 编译 + 测试 + Lint
- `make build` ✅ 编译通过
- `make test` ✅ 392/392 测试通过，0 失败
- `make lint` ✅ 0 violations

### Wave 2: 代码审查
Code Reviewer 发现 2 Critical + 4 Important，全部已修复：
1. ✅ Critical: `cancelDrag` 扩展处理 `isLanding` 阶段（防窗口永久展开）
2. ✅ Critical: `switchState` 拖拽保护收紧为全部 queue（防 `.idle` 穿透破坏落体序列）
3. ✅ Important: dust 粒子 action 添加 key（cancelDrag 可清理）
4. ✅ Important: grabbed 动画帧设置顺序修正
5. ✅ Important: landing squash facingSign 从 `facingRight` 读取（非 `xScale`）
6. ✅ Important: `playFrightReaction` 添加 `isDragOccupied` 豁免

修复后重新验证：build ✅, test 392/392 ✅, lint 0 violations ✅

## 变更日志
- [2026-04-20T15:39:26Z] autopilot 初始化，目标: 给猫咪增加长按拖拽的功能 1. 长按后可以拖拽到另外一个地方 2. 皮肤包设置了多一个被拖拽过程中的状态配置，历史的做好降级 3. 猫咪下落是做好设计 整体要自然有趣且符合逻辑
- [2026-04-20T16:15:00Z] deep design 完成：Q&A 5 轮澄清 + Plan Reviewer 审查通过（修复 2 个 BLOCKER：BuddyScene update 豁免、softSeparation 豁免）
- [2026-04-20T16:20:00Z] 设计方案审批通过，进入 implement 阶段
- [2026-04-21T00:10:00Z] 实现完成：6 个文件修改 + 1 个新文件。make build ✅, make test 392/392 ✅, make lint 0 violations ✅
- [2026-04-21T00:17:00Z] QA 完成：代码审查发现 2 Critical + 4 Important，全部修复并重新验证通过。进入 merge 阶段
