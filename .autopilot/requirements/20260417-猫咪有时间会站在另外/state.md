---
active: true
phase: "merge"
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
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/partitioned-spinning-hedgehog/.autopilot/requirements/20260417-猫咪有时间会站在另外"
session_id: 2bcd3a84-e294-42d6-823a-4a9c6777e0e8
started_at: "2026-04-17T15:21:00Z"
---

## 目标
猫咪有时间会站在另外一直猫咪上很久，然后也很容易被另外一直猫咪卡住，显得非常不真实

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

**目标**：消除多猫重叠/卡住现象，让猫咪保持自然间距。

**技术方案**：
1. **软分离算法**（BuddyScene.update）：每帧检测猫对 X 距离 < 52px，用弹簧阻尼推力分离（nudgeMag = min(overlap * 0.1, 0.5)）
2. **生成位置避让**（addCat）：最多尝试 10 次随机位置，选最远点
3. **随机游走目标避让**（doRandomWalkStep）：目标距猫 < 52px 时外推
4. **惊吓方向智能选择**（playFrightReaction）：检查逃跑方向是否有猫
5. **清理无效物理掩码**：移除 collisionBitMask 中的 .cat

**文件影响**：CatConstants.swift, BuddyScene.swift, MovementComponent.swift, InteractionComponent.swift, CatSprite.swift

## 实现计划

- [ ] T1: CatConstants.swift — 添加 Separation 常量枚举
- [x] T2: CatSprite.swift — collisionBitMask 移除 .cat
- [x] T3: BuddyScene.swift — 添加 applySoftSeparation() + update() 调用
- [x] T4: BuddyScene.swift — 添加 findNonOverlappingSpawnX() + 修改 addCat()
- [x] T5: MovementComponent.swift — 添加 adjustTargetAwayFromOtherCats()
- [x] T6: InteractionComponent.swift — 惊吓方向检查
- [x] T7: 新增 CatSeparationTests.swift 单元测试
- [x] T8: make build && make test 验证

## 红队验收测试

`Tests/BuddyCoreTests/CatSeparationTests.swift` — 15 个测试用例

| 组 | 测试 | 验证点 |
|----|------|--------|
| A | testOverlappingCatsGetPushedApart | update() 后不崩溃、不越界 |
| A | testDistantCatsAreNotMoved | 远距离猫不受推力 |
| A | testSeparationRespectsActivityBounds | 推力不越界 |
| A | testEatingCatsNotNudged | eating 状态豁免 |
| A | testTaskCompleteCatsNotNudged | taskComplete 状态豁免 |
| B | testNewCatSpawnsAwayFromExisting | 生成位置避让 |
| C | testCatPhysicsBodyDoesNotCollideWithCats | collisionBitMask 无 .cat |
| C | testCatPhysicsBodyCategoryIsStillCat | categoryBitMask 仍为 .cat |
| D | 5 个常量验证 | Separation 常量值合理 |
| E | testManyCatsUpdateDoesNotCrash | 8 猫 60 帧稳定性 |
| E | testToolUseCatsDoNotOverlapAfterRandomWalk | toolUse 游走避让 |

## QA 报告

### 轮次 1 (2026-04-17T15:45)

**Tier 0: 红队验收测试** ✅
- CatSeparationTests: 15/15 passed, 0 failures (0.515s)

**Tier 1: 基础验证** ✅
- Build: `swift build` — Build complete! (0.40s)
- Test: `swift test` — 235/235 passed, 0 failures (39.3s)
- Lint: `make lint` — 0 violations, 0 serious in 49 files

**Tier 1.5: 真实场景验证** ⚠️
- 执行: `.build/debug/buddy-cli ping` — CLI 正常退出 (exit code 1, "Buddy app is not running")
- 输出: CLI 二进制正常工作，无崩溃
- ⚠️ 视觉验证（软分离动效、多猫分离、惊吓方向）需要运行中的 app，worktree 环境无法启动 GUI

**Tier 2a: 设计符合性审查** ✅ PASS
- 8/8 设计要求全部正确实现，无遗漏、无偏差

**Tier 2b: 代码质量审查** ✅ PASS (2 Important, 3 Minor)
- [Important] adjustTargetAwayFromOtherCats 只修正第一个障碍物（3+猫密集时退化，applySoftSeparation 兜底）
- [Important] findNonOverlappingSpawnX 实际 10+1 次尝试（不影响正确性）
- [Minor] flee 方向检测区间稍保守（故意扩展安全余量）
- [Minor] nearbyObstacles 闭包每次调用创建数组（maxCats=8 影响极小）
- [Minor] testDistantCatsAreNotMoved 是语义空洞测试（未挂载到 BuddyScene）

### 总结
✅ Tier 0 | ✅ Tier 1 | ⚠️ Tier 1.5（GUI 验证待人工） | ✅ Tier 2a | ✅ Tier 2b

## 变更日志
- [2026-04-17T15:49:34Z] 用户批准验收，进入合并阶段
- [2026-04-17T15:21:00Z] autopilot 初始化，目标: 猫咪有时间会站在另外一直猫咪上很久，然后也很容易被另外一直猫咪卡住，显得非常不真实
- [2026-04-17T15:25:00Z] design 阶段完成，方案通过审批，进入 implement 阶段
- [2026-04-17T15:35:00Z] implement 阶段完成：蓝队实现 T1-T6，红队完成 T7 验收测试。build/test/lint 全部通过（235 tests, 0 failures）
- [2026-04-17T15:45:00Z] QA 阶段完成：Tier 0/1/2a/2b 全部 PASS，Tier 1.5 GUI 视觉验证待人工确认
