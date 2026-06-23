# brainstorm.md — 菜单栏设置页产品与交互优化

## 探索的目的与约束

**用户目标**：深入分析当前菜单栏点击后的设置页产品/交互设计，输出优化方案。

**本次范围（用户确认）**：聚焦**结构优化**——把设置窗口从 segmentedControl 拼凑形态重组为原生设置中心骨架。**AI 配置（provider/model/API key 进 UI）暂不在本次范围**，后续单独迭代。

**项目上下文探索关键发现**（已读源码 + 近期 commit）：
- 当前"设置页"= `SettingsWindowController`（`SettingsWindowController.swift:8-114`）：600×540 浮动 `SettingsPanel`(NSPanel) + 顶部 `NSSegmentedControl` 切 3 个 tab：**皮肤 / 插件 / 热键**。
- 入口链路：菜单栏 NSStatusItem → 点击弹 `SessionPopoverController` popover → 齿轮按钮 `onSettings` → `AppDelegate.showSettings()`（`AppDelegate.swift:336-346`）。
- 三个 tab 内容：皮肤（NSCollectionView 网格 + 音效/标签开关）、插件（列表 + 启用/禁用 + 错误恢复）、热键（自定义 `HotkeyRecorderView` + 大字回显 + 重置）。
- **核心矛盾**：窗口叫"设置"，形态却是"皮肤商店 + 插件管理 + 热键"三 tab 拼凑，缺乏原生设置中心的正经产品感与清晰信息架构。
- **已知缺口（本次不处理）**：真正的 AI provider / model / API key 配置完全不在 UI，只能 `buddy launcher config set/use` CLI 或手编 `~/.buddy/launcher.json`。记为后续单独需求，本次结构骨架为其预留 sidebar 扩展位即可。
- 存储分散在 4 处：UserDefaults（音效/标签/tab 选择/热键）、Keychain（API key）、`~/.buddy/launcher.json`（provider/model/kind）、`~/.buddy/launcher-trust.json` + `launcher-plugins/`（插件）。
- 既有先例可复用：`SettingsTabClickReceiver` 协议、`switchTo(tab:)`、`SettingsPanel.sendEvent` 点击转发（解决 LSUIElement 无法成为 key window）、NSHostingController SwiftUI↔AppKit 桥接、`QueryHandler.handle` socket 双向 query（CLI↔app 通道）。

**明确约束（用户确认）**：
- 痛点多选（本次范围）：① 信息架构重组 ② 为扩展性铺路。（交互细节打磨非重点）
- 成功标准第一优先级：**正经产品感**——视觉/交互像成熟的 macOS 应用设置中心，不再是"皮肤商店+热键"拼凑感。这决定了方案加权：产品质感 > 功能补齐 > 扩展性。
- 技术栈：Swift / AppKit 为主，已有 SwiftUI↔AppKit 桥接先例；LSUIElement accessory app 约束（key window 问题需 sendEvent 方案）。

## 候选方案与权衡

### 方案 A：macOS 系统设置风格 · 左侧 sidebar（✅ 选定）
- 形态：标准 NSWindow（可调大小，不再浮动）+ `NSSplitViewController` 左 sidebar 导航 + 右详情区。
- sidebar 分类：皮肤 / 插件 / 热键 / 通用 / 关于（顺序待定）。为后续 AI 配置等新分类预留扩展位。
- 皮肤/插件从窗口主角降为 sidebar 普通分类。
- 优势：最贴近 macOS 原生设置，**正经感最强**（直击第一优先级）；扩展性最强（加设置=加一行 sidebar）；根治"商店拼凑感"；未来加 AI 配置/自启/通用/通知零结构改动。
- 劣势：窗口变大、失去现状轻盈浮动感；窗口骨架需重写（工作量最大的一次性投入）；皮肤/插件的 NSCollectionView 要嵌入 sidebar 详情区。

### 方案 B：顶部 tab 重组 · 保持浮动小窗
- 形态：保持 ~600×540 浮动 NSPanel，segmentedControl 扩到 4-5 个（通用/皮肤/插件/热键），各 tab 内统一视觉语言。
- 优势：改动最小、风险低，复用现有 segmentedControl 机制；保持轻盈浮动感。
- 劣势：tab 到 4-5 个会挤，**扩展性见顶**（违背"为扩展性铺路"）；形态没质变，仍是"一堆 tab"，正经感打折。

### 方案 C：sidebar + 子分段（两级导航）
- 形态：左 sidebar 大类 + 右上 sub-segment 子分类。
- 优势：两级导航容量最大。
- 劣势：对当前规模**过度设计（YAGNI）**；复杂度最高；正经但偏重。

## 选择与理由

**选定方案：A（macOS 系统设置风格 · 左侧 sidebar）**

**选择理由**：
- 用户把"正经产品感"明确列为第一优先级，而 sidebar 是 macOS 原生设置（System Settings / Xcode Preferences）的标准形态——用户学习成本最低、视觉正统性最强。
- sidebar 天然解决"信息架构重组"：左侧分类列表清晰分层，皮肤/插件/热键/通用/关于各归其位。
- "为扩展性铺路"在 sidebar 下是免费的——未来加任何设置类别（含后续 AI 配置）只需加一行 sidebar item，零窗口结构改动。
- 顺手根治"商店拼凑感"：皮肤/插件从"窗口主角"降为 sidebar 上一行普通分类，窗口主角变成"设置"本身。
- 代价（窗口变重、骨架重写）是一次性投入换长期收益，且用户已接受方向。

**被排除方案及原因**：
- B：扩展性见顶（tab 数有上限）、形态没质变，与"正经产品感 + 扩展性"两条诉求都冲突，只是"现状打补丁"。
- C：当前设置项规模撑不起两级导航，属过度设计；复杂度高，收益不匹配。

## 待主 SKILL 接力的设计决策

以下点已在方向上对齐，具体值留待设计文档深化（主 skill 接力时与用户确认）：

1. **sidebar 分类清单与顺序**：候选 = 皮肤 / 插件 / 热键 / 通用 / 关于。需定顺序；"通用"含哪些（音效、标签、开机自启等偏好是否合并到此）；"关于"含版本/反馈/开源地址。
2. **皮肤/插件降权后的归属**：保持独立 sidebar 分类（方案 A 默认）；还是合并为"外观/扩展"单分类以精简 sidebar。需结合 NSCollectionView 在详情区的布局再定。
3. **窗口实现技术**：纯 AppKit（`NSWindow` + `NSSplitViewController` + 现有 NSCollectionView）保持一致；还是 sidebar 骨架用 SwiftUI（`NavigationSplitView`）桥接。倾向纯 AppKit（与既有 tab VC 体系一致，风险低），但 SwiftUI 重写更省代码——设计文档评估。
4. **窗口形态参数**：标准 NSWindow（非 NSPanel）、可调大小、最小/初始尺寸（如 760×540）、是否保留"点击外部隐藏"行为（标准窗口通常不隐藏，行为改变需确认）。
5. **既有点击转发机制**：`SettingsPanel.sendEvent`（解决 LSUIElement key window）在标准 NSWindow 下是否仍需要；`SettingsTabClickReceiver` 协议如何演进为 sidebar selection 协议。
6. **存储统一（本次偏好层）**：是否借本次重组收敛 UserDefaults 偏好读写入口到统一 `SettingsStore`。**注**：Keychain / `launcher.json`（AI 配置存储）随 AI 配置后续一起动，本次不碰。
7. **popover 入口（齿轮按钮）**：是否调整；菜单栏菜单结构是否新增独立入口（本次倾向只动设置窗口本体，popover/菜单不改，待确认）。

## 后续范围（本次不做，记录待办）

以下与 AI 配置相关，本次结构优化为其预留 sidebar 扩展位，但不实现：

- **AI 配置 UI 深度**：是否对齐 CLI 多 provider（`config set` 多个 + `config use` 激活）能力（列表 + 添加/编辑/删除 + 激活）还是简化为单 provider；model 选择方式（下拉预设 vs 自由输入 vs 两者）；是否做"测试连接"按钮（调用一次 ping 验证 key/baseURL）。
- **CLI ↔ UI 一致性**：AI 配置 UI 操作必须与 `buddy launcher config` CLI 走同一存储（`~/.buddy/launcher.json` + Keychain），不引入双轨。倾向复用 `QueryHandler` socket 双向命令（已有热键 tab 先例），UI 改配置 → socket → app 写文件，避免 UI 直写文件格式。
