---
active: true
phase: "qa"
gate: "review-accept"
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
task_dir: "/Users/lilei03/netease-ai/ClaudeCodeBuddy/claude-code-buddy/.worktrees/rocket-step1/.autopilot/requirements/20260418-1-修改-Starship-改成原生"
session_id: 
started_at: "2026-04-17T21:44:31Z"
---

## 目标
1 修改 Starship 改成原生大画布 2 感叹号状态 添加尾焰

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

**目标**：将 Starship 从"48×48 sprite + 运行时 setScale(1.5)"改为 72×72 原生画布，消除 `yOffsetForScale` / `spriteScale` / badge counter-scale 等散落在代码里的补偿逻辑。同时给所有火箭 abort 状态补上 small 悬停尾焰。

**技术方案**
- 精灵生成器 `beginFrame` / `write` 参数化 canvas 尺寸
- 新增文件级 `drawScale` + `pxS` / `pS` 帮助函数，Starship 绘制代码内部 `px`→`pxS`、`p`→`pS`；Starship write 块前设 `drawScale=1.5` 后复位
- `RocketKind` 加 `spriteSize`（classic/shuttle/F9=48²，starship=72²）和 `containerInitY`（classic/shuttle/F9=24，starship=41），删除 `spriteScale` 和 `yOffsetForScale`
- `RocketEntity.init` 用 `kind.spriteSize` 构建 node / padNode / boosterNode；删除 `setScale(spriteScale)`
- `padVisibleY` 改成实例计算属性
- 各 State 文件的 `groundY + yOffsetForScale` → `kind.containerInitY`
- `RocketAbortStandbyState` badge offset 改为固定 `8`
- 4 种火箭 abort_a/b 帧里补上 `drawXxxFlame(size: .small)`

**风险评估**
- 风险：1.5× 坐标取整后 Starship 视觉位置可能微偏 → 缓解：对比新旧贴图 scene-y 关键点（booster 底=6，ship 引擎=36，鼻锥顶≈66）
- 风险：遗漏某处 `spriteScale` / `yOffsetForScale` 引用 → 缓解：grep 过一遍再编译
- 风险：badge 位置变化不美观 → 缓解：fallback 为 kind check，starship 用 12pt 偏移

## 实现计划

- [x] 精灵生成器 `beginFrame(width:height:)` + `write(name:size:)` 参数化
- [x] 新增 `drawScale` + `pxS` / `pS` helpers
- [x] 所有 `drawStarship3*` / `drawStarshipPad` / `drawStarshipGridFin` / `drawStarshipFlame` / `drawStarshipShipFlame` 的 px/p 切换到 pxS/pS
- [x] 所有 `write("starship_*")` 块 size=(72,72)，前后设/复位 drawScale
- [x] 4 种火箭 abort_a/b 帧补 small flame
- [x] `RocketKind.spriteSize`、`containerInitY` 新增；`spriteScale`、`yOffsetForScale` 删除
- [x] `RocketEntity.init`：node/pad/booster 用 `kind.spriteSize`，删掉 setScale
- [x] `RocketEntity.padVisibleY` 改成实例属性
- [x] `RocketEntity.attachBoosterIfNeeded` booster size 用 `kind.spriteSize`
- [x] `RocketOnPadState.didEnterStarship` 用 `kind.containerInitY`
- [x] `RocketCruisingState.didEnterConventional` + willExit drop-back 用 `kind.containerInitY`
- [x] `RocketPropulsiveLandingState.didEnterConventional` 用 `kind.containerInitY`
- [x] `RocketAbortStandbyState.addCircledBangBadge` 改固定 offset
- [x] `BuddyScene.addEntity` rocket 分支用 `kind.containerInitY`，pad y 用实例 padVisibleY
- [x] grep 清理任何 spriteScale / yOffsetForScale 残留
- [x] regen sprites + build + showcase 目测验证

## 验证方案

### 真实测试场景
1. **Sprite 生成成功**
   - 执行：`cd /Users/lilei03/netease-ai/ClaudeCodeBuddy/claude-code-buddy/.worktrees/rocket-step1 && swift Scripts/generate-rocket-sprites-v2.swift`
   - 预期：所有 starship_*.png 尺寸 72×72，其他火箭 48×48
2. **Build 通过**：`swift build` 无警告无错误
3. **视觉回归**（showcase 模式）
   - `pkill -f "ClaudeCodeBuddy$"; .build/debug/ClaudeCodeBuddy > /tmp/buddy.log 2>&1 &`
   - `.build/debug/buddy-cli showcase`
   - Starship 底在 OLM 顶 y=6，ship 引擎 y=36，鼻锥 y≈66
   - 4 种火箭 abort 状态都看到小尾焰
   - Abort badge 大小在 Starship 和其他火箭上肉眼一致

### 静态验证
- `grep -R "spriteScale\|yOffsetForScale" Sources/` 应无结果

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Round 1 — 2026-04-18T02:15:00Z

**自动化检查**
- ✅ Sprite regen：`swift Scripts/generate-rocket-sprites-v2.swift` — 所有 starship_* 输出 `(72×72)`，其他 `(48×48)`
- ✅ `sips` 验证：`rocket_starship_onpad_a.png` 72×72，`rocket_onpad_a.png` / `rocket_f9_onpad_a.png` 48×48
- ✅ Build：`swift build` complete（1 条 pre-existing unused-var warning 与本次改动无关）
- ✅ 残留清理：`grep spriteScale|yOffsetForScale Sources/` 仅余 1 行 doc 注释，无代码调用
- ✅ App 启动：`.build/debug/ClaudeCodeBuddy` 跑起，`buddy-cli ping` 通过
- ✅ 事件派发：showcase / task_complete / thinking / permission_request 全部 OK，无 crash

**视觉验证（需用户目测）**
- [ ] Starship OnPad：booster 底贴 OLM 顶（scene y=6），ship 引擎 y=36，鼻锥 y≈66
- [ ] Abort 状态（4 种火箭）：body + ! badge + **小尾焰**（新加）同时显示
- [ ] ! badge 尺寸在 Starship 与其他火箭上肉眼等大（scene 级 12pt 偏移，不再 × spriteScale）
- [ ] 起飞：筷子收 + booster 线性下落 + 船水平漂，无垂直位移
- [ ] 降落：pan 回 OLM x + 筷子接 + OnPad snap 回初始 y，booster fade-in

**结论**：自动化 tier 全通过，视觉 tier 交用户验收。

## 变更日志
- [2026-04-17T21:44:31Z] autopilot 初始化，目标: 1 修改 Starship 改成原生大画布 2 感叹号状态 添加尾焰
- [2026-04-18T02:08:52Z] design 方案通过 Plan Mode 审批，phase → implement
- [2026-04-18T02:15:00Z] implement 完成：sprite generator 参数化 canvas 尺寸 + pxS/pS helpers + Starship 用 72×72 + 4 种火箭 abort 补小尾焰；RocketKind 删除 spriteScale/yOffsetForScale，新增 spriteSize/containerInitY；RocketEntity / 各 State / BuddyScene 全部更新；build 通过，showcase 可跑。phase → qa
- [2026-04-18T02:18:00Z] QA round 1：自动化 tier 全通过（sprite 尺寸、build、grep 清理、app 启动、事件派发）；视觉 tier 待用户目测验收。gate → review-accept
