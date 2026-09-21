# BUDDY_OUTPUT_CARD 第三结构化输出通道：clamp 双侧防御 + card 存在不 yield .text

<!-- tags: launcher, card-channel, buddy-output-card, command-mode, plugin, stdin-executor, clamp, defense-in-depth, plugin-card, agent-event -->

**Scenario**: quota→gcli 插件的套餐限额是多条目结构化数据（条目名/状态等级/多窗口百分比+重置时间），纯文本 stdout 排版上限低（emoji+全角空格对齐被用户判「丑」）；面板另有「有输出固定撑满 400pt」的独立问题。

**Choice**:
- **第三通道 `BUDDY_OUTPUT_CARD` 完全对称 2026-06-19 image/candidates 先例**：StdinExecutor 注入 env 指向 `/tmp/buddy-plugin-<uuid>.card.json`（`cardMaxBytes=262_144`），exit 0 后 `readCardOutputSafely`（resolvedPath 防 symlink + 超限/解码失败→nil 静默降级 + finally 删临时文件）→ `PluginResult.card` → `AgentEvent.card(PluginCard)` → `LauncherCardView`（LauncherTheme token：进度条/状态色/等宽数字）。
- **schema 通用化**（title/entries/name/level/badge/windows[label/percent/reset]，无 quota 专有名词）——未来插件可复用；`level` 闭集 ok/warn/danger 与阈值 60/85 契约钉死。
- **clamp 双侧防御**：Python 产出前 clamp percent 到 [0,100] + Swift 解码侧再 clamp、entries>32 截断保留前 32——「安全不依赖插件自觉」，第三方插件写越界值时框架侧行为确定。
- **展示互斥**：card 存在时不 yield `.text`（防同内容双份，红队 s7p3 计数断言钉死）；旧版 app 不认识新 env 自然走 stdout 文本 = 免费前向兼容。
- 兜底语义收口：pluginCrash 兜底条件补 `&& card == nil`（card 存在即视为有产出）。
- 插件降级路径（含「没有名称匹配」）`card=None`——防 0 条目卡片吞掉无匹配提示。

**Rationale**: 仿既有通道是正交加法（AgentEvent 穷尽 switch 编译器兜底，不改既有路径）；stdout 恒保留人类可读文本作降级兜底，插件升级对旧 app 无损；渲染层卡片比 markdown 文本上限高一个量级。

**Evidence**: state.md 设计文档/场景 7（20260921-开始实现）；StdinExecutor.swift `readCardOutputSafely`；PluginCard.swift clamp+截断；LauncherCardView.swift；24 验收谓词全绿 + 用户真机两轮目视验收（auto-fix 一轮修卡片水平 padding：插入点漏 `.padding(.horizontal, 20)` 致贴边）。

**Trade-offs**: `estimatedOutputHeight` 与 LauncherCardView 布局常数为注释级 1:1 耦合——改 spacing 会漂移，靠快照测试 + 高度纯函数单测双兜底。

**关联**: [[2026-06-19-command-mode-image-channel-bypass-agent-loop]]（通道机制母先例「5+1 处穷尽 switch」）、[[2026-09-20-cc-switch-quota-plugin-command-mode-python3]]（本通道首个消费者）。
