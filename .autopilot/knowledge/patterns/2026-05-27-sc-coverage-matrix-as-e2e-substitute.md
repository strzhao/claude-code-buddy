---
name: sc-coverage-matrix-as-e2e-substitute
description: 多任务 DAG 末尾的"端到端验收"任务用 SC 覆盖矩阵证明现有测试已覆盖，避免重复造 e2e 测试；仅补缺漏 SC 的新测试 + 文档归档
metadata:
  type: pattern
---

# SC 覆盖矩阵替代重复 e2e 测试，作为多任务项目验收兜底

<!-- tags: project-mode, dag, e2e, acceptance-scenario, coverage-matrix, autopilot, sc-mapping, audit, brief-mode, anti-duplicate-testing, final-task -->

## 上下文

autopilot 项目模式把一个大需求拆为 N 任务 DAG（每个任务独立 design/implement/qa/merge）。每个任务通常都做自己范围内的红队验收测试。等到 DAG 最后一棒（如 task 007 "端到端验收 + 文档"），如果照字面意思"端到端验收"会想：

- 再写一套 `LauncherE2ETests.swift` 覆盖 SC-01..SC-12 全部 12 个场景
- 每个 SC 一个 test method，启动 mock provider + mock plugin + 模拟用户输入

但这样**90% 是重复造**：前 6 个任务的红队验收测试已经各自覆盖了所属 SC 的核心断言（task 002 红队覆盖 SC-02/SC-07/SC-12，task 004 红队覆盖 SC-04/SC-05，task 006 红队覆盖 SC-04/SC-05/SC-06/SC-09/SC-11 等）。重写 e2e 只是把这些断言重新组织一遍，并不增加真实覆盖率。

## 模式

**用 SC 覆盖矩阵替代重复的 e2e**：

1. 列出全部 N 个验收场景（SC-01..SC-N）
2. **逐 SC 检索现有测试文件**（grep 测试文件名 + SC 注释），填入"覆盖测试文件"列
3. 找出未被覆盖的 SC（通常 1-3 个，常是跨任务的"非功能"约束，如本项目的 SC-10 "Launcher 与像素猫互不干扰"）
4. **只为缺漏的 SC** 写新测试（蓝队 + 红队互补）
5. 把矩阵作为 markdown 归档到 `.autopilot/project/sc-coverage.md`，作为 future audit 追溯入口

## 模板

```markdown
| SC | 验收场景 | 覆盖测试文件 | 关键测试方法 | 状态 |
|---|---|---|---|---|
| SC-01 | 全局快捷键召唤与隐藏 | `LauncherHotkeyAcceptanceTests.swift` | (path) | ✅ 已覆盖 |
| ... | ... | ... | ... | ... |
| SC-10 | Launcher 与像素猫互不干扰 | 🆕 LauncherIsolationTests.swift | (本任务新增) | ✅ task N 新增 |
```

矩阵末尾汇总统计：
- 现有测试文件数
- 本任务新增数
- 测试套件总计 (前 N-1 任务末态 + 本任务新增)
- 覆盖维度（如 SC-10 用双视角：静态契约 + 独立 grep 验证）

## 取舍

- **Pro**: 90% 减少代码量（task 007 实际新增 4+4=8 测试 vs 12 SC×~10 测试=120 重复测试），节省 ~3h 开发时间和持续维护负担
- **Pro**: 矩阵本身是文档，未来 PRD 改了 SC 编号，audit 可秒级定位影响的测试文件
- **Pro**: 强制审视"哪些 SC 真的没被覆盖"，反而暴露过去任务遗漏的隐性 SC（本项目正是这样发现 SC-10 隔离测试一直缺）
- **Con**: 矩阵需要人工维护，测试重命名时需同步（建议 `/autopilot doctor` 定期检查 SC ↔ 测试文件映射一致性）
- **Con**: 不适合"前置任务的红队测试本身可信度低"的情况（此时确实需要兜底重测，但前提是前置任务的红队质量评估出问题）

## 何时用

- ✅ 多任务 DAG 的最后一棒标"端到端验收 + 文档"
- ✅ 前置任务都有红队验收测试（autopilot 标准流程产出）
- ✅ PRD 验收场景列表稳定（如 prd.txt Genie 11 决策）
- ❌ 项目从零开始无前置测试积累
- ❌ 前置任务红队测试质量不可信（已被 plan-reviewer 或 qa-reviewer 标记多次 ⚠️）

## 何时不用

- 真实端到端 e2e（启动整个 app、模拟用户键盘鼠标、断言 UI 渲染）确实有不可替代价值的场景：跨任务集成的状态机串扰、并发竞态、性能回归。这些用 SC 矩阵无法覆盖，仍需写 e2e 测试。
- 但 task 007 这种"测试 + 文档收尾"任务里很少触发，因为 SC 验收的颗粒度通常已经在前置任务覆盖。

## How to apply

在 autopilot brief 模式遇到 task X = "端到端验收 + 文档" 时，design 阶段：

1. 先 `Explore` agent 全量扫描 `tests/` 目录，提取每个测试文件的 SC 注释
2. 与 PRD 的 SC 列表做 cross-join 得到初版矩阵
3. 设计文档明确声明"本任务不重复造 e2e，仅补 [SC-X..Y] 缺漏"
4. plan-reviewer 审查时要求设计有"SC 覆盖矩阵"章节
5. implement 阶段只为缺漏 SC 写新测试（蓝+红互补）
6. merge 阶段把矩阵归档到 `.autopilot/project/sc-coverage.md`

## 关联

- [[swift-file-path-test-upcount]] 用 #file 扫描源码做静态契约断言时的层数陷阱
- task 007 实际落地：12 SC 中 11 个被现有 856 tests 覆盖，仅 SC-10 新增 8 测试（蓝 4 + 红 4），最终 864 tests 0 failures，验证矩阵法可行
