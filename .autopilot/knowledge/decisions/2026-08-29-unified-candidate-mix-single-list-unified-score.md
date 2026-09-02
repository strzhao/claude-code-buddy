# 插件候选一等公民：统一分数体系 + 单列表混排（取代方案 B 分区渲染）

<!-- tags: launcher, unified-score, single-list, candidate, plugin, app-search, tab-lock, enter-exec, tier, c-unified-score, watermark-chip-retired, command-prefix-retired -->

**Scenario**: Launcher 搜索里插件是二等公民——唯一视觉信号是输入框右上角文字 chip，且三条排序管线互不合并（command 严格前缀无分数 / 内置 priority 排序 / stdin+prompt contains 打分完全不进列表）。用户要求插件与 app 搜索同等待遇并整体参与排序。

**Background**: 三条候选管线各有历史包袱：command 严格前缀（输不完整前缀完全不出现）、watermark chip 纯展示不可点、CandidateZone 四区 + 跨区导航复杂度。

**Choice**:
- **统一分数档位**（纯函数 scorer，一处定义三处消费：typing 候选 / AI 流缩候选内核 / route 短路）：完全 1000 / 前缀 800（**双向**：query⊆keyword 输入中 + query 以 keyword 开头+严格分隔的 keyword+参数形态）/ 词首 500（分词后任一词开头连续段 + 首字母缩写）/ contains 150；name 命中 +30；排序键 (score desc, 来源序[内置 priority>社区 50>app 0], title)，截 8。
- **插件候选桥接为通用 Action 模型**（icon emoji 字段而非 NSImage——SwiftUI Text 渲染最干净）进 app/内置同一列表、同一行渲染器。
- **Enter 直接执行**（参数 = 剥离触发词）取代「锁定→再 Enter」两段式；Tab 手动锁定保留；自动锁定/chip/独立分区/跨区导航全部退役（净删码）。
- **单字 keyword（长度 <2）仅参与完全档**：多字误命中防线（「密码」contains「码」），与 AI 流 tool description/路由 prompt 触发词过滤（effectiveTriggerKeywords）双通道堵漏。

**Alternatives rejected**:
- 桥接归一层（保留三管线 + score 归一桥）：两套分数体系长期并存，严格前缀问题只被补丁式放宽。
- 统一 CandidateProvider 流式架构：现状各源同步计算无流式需求，YAGNI，改动面最大。

**Trade-offs**: 触碰 updateQuery/submit 核心流需调参与全量回归；档位阈值是产品调参空间（如同名 app 与插件完全匹配竞逐时由位置加成/name 加成细分）。核心收益：交互/视觉/排序真正统一 + 净删码（状态机/chip/独立区/跨区导航四块退役）。

（核对锚点：2026-08-29 源码版本）

**关联**: [[2026-07-01-command-dual-path-ui-vs-ai-flow]]（双路径防线的上游原则）、[[2026-05-30-launcher-builtin-plugin-direct-action-pipeline]]（内置插件体系基础）。
