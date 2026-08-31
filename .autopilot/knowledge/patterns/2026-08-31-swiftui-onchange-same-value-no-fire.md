# SwiftUI onChange(of:) 赋相同值不触发 — 编程式状态驱动须手动直调

**日期**: 2026-08-31
**tags**: swiftui, onchange, equatable, same-value, no-fire, state-driven, idempotent, updatequery, launcher, builtin-expand, empty-history, dead-angle, verify-before-assume

## 教训（Lesson）
`TextField` 的 `.onChange(of: query)` 基于 Equatable 比较，**赋相同值不触发**。launcher 内置插件「展开=填触发词」方案（Enter → `query = trigger` 靠 onChange 驱动 `updateQuery` 刷候选）在边界态静默失效：剪贴板历史为空时输入完整触发词（`paste`）仍出聚合行（无具体候选不去重），Enter → `.expandBuiltin("paste")` → `query = "paste"` 与当前值相同 → onChange 不 fire → `updateQuery` 不执行 → 列表原地不动，用户连按 Enter 永无反馈。qa-reviewer（非测试——16 谓词全假设历史非空，谓词闸门抓不到）靠代码审查路径分析抓出。

## 选择（Choice）
- 编程式状态驱动**不能依赖 onChange 副作用**，须手动直调目标方法：`query = trigger` 后追加 `manager.updateQuery(trigger)`——幂等（内部 cancel 旧 debounce 重启），值不同时与 onChange 双触发无害。
- 测试锚定：View 分支本身无测试通道（private + @State），用「manager 层 seam 直调锁前半段（空历史 mock：keywords 全 4 词但 actions 恒 []）+ enum 穷尽性编译守卫锁分支存在」组合；全称量词验收谓词要警惕**边界前置假设**（历史非空），充分性反查（谓词 vs diff 风险面）是谓词闸门之外的必要人工审查。

## 如何应用（How to apply）
- 任何「改 @State 值 → 靠 onChange 驱动下游」的交互设计，先问：**赋值与现值相同时链条还通吗？**（空列表态、重复点击、重入）不通则在赋值处补直调。
- 与 [[2026-07-15-swiftui-scrollviewreader-onchange-let-binding-center-half-cell]] 同族：onChange 的触发条件误解是 launcher 交互方案的高频坑（上次是 let 不可监听，这次是同值不触发）。
- 验收谓词设计时对「前置条件」做反例审计（本例前置=历史非空，恰漏掉死角态）。
