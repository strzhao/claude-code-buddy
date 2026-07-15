# brainstorm — launcher 候选列表超阈值不可见 / 选中不滚动

## 探索的目的与约束

**用户目标**：snip 有 8 个 item，launcher 输入 `snip` 后面板只展示 5 个；键盘下移到第 6 个时光标（选中高亮）看不见、第 6 个 item 也看不到。修好这个交互。

**项目上下文探索关键发现（已读码确认，非命名推断）**：

1. 两个 snip UI 要区分——bug 不在设置面板：
   - `SnipPanelVC.swift`（设置页 snip 管理）有 `NSTableView` + `NSScrollView` + `scrollRowToVisible`（line 240），**不是** bug 位置。
   - bug 在 **launcher 弹窗候选列表**：`LauncherInputView.swift` + `LauncherPluginCandidateView.swift`。

2. 候选列表 `LauncherPluginCandidateView`（`LauncherPluginCandidateView.swift:16-38`）是**纯 `VStack`，没有 ScrollView / ScrollViewReader**——8 行全排下去，无任何滚动容器。（Explore agent 初判"已有 ScrollView 加 scrollTo 即可"是误读：`LauncherInputView.swift:164` 的 `ScrollView` 包的是**输出区** markdown/图片/错误，不是候选列表。）

3. `panelHeight`（`LauncherInputView.swift:632-666`）把面板高度钉死：`min(pluginCandidateCount, 5) * 44`（line 647），commandRoute/instant 同样 `min(count, 5) * 44`（line 653/654），lastRoute `min(effectiveCount, 5)`（line 662）。**只给 5 行高度** → 第 6-8 行被面板窗口裁掉。

4. `navigateUp/navigateDown`（`LauncherInputView.swift:347-428`）只改 `pluginCandidateIndex` / 各区 selectedIndex，**不滚动**（也没东西可滚）。

5. "光标看不见 + 第 6 个看不见"是**同一根因**：选中行落到被裁掉的 6-8 行区域，sage 高亮（`LauncherPluginCandidateRow` line 65 `.background(isSelected ? primary.opacity(0.18) : clear)`）画在面板可视区外。

6. **范围是通用问题**：`panelHeight` 对四个候选来源（plugin/commandRoute/instant/lastRoute）都 `min(count,5)` 封顶、对应视图都没滚动。任何 >5 候选的插件都中招，snip 只是首个触发者（AppLauncher 搜 `a` 返回 50 个同样会中）。

**明确约束**：
- 遵循现有 Alfred/Raycast 视觉风格（CLAUDE.md 反复强调）；选中高亮已是 sage pill，不变。
- 用户判断"不复杂"：每次查询候选数确定，无动态切换跳变；混合模式一次定性。
- `min(count, T)` 本身就是混合语义，当前只是 T=5 太小。
- GUI/布局类改动 headless `swift test` 有盲区（CLAUDE.md QA 铁律 + patterns/2026-07-09），须真机 E2E 验证滚动行为。

## 候选方案与权衡

### 维度一：候选超可视区时的交互方式

**方案 A：纯滚动固定视口**（5 行封顶 + 滚动跟随选中，Alfred 纯正风格）
- 优势：面板高度恒定，任意数量都适用；肌肉记忆好（选中屏位稳定）。
- 劣势：用户当前 8 个也想全看到，固定 5 行仍需滚动才能看到第 6-8。

**方案 B：面板自适应全展示**（无上限，按实际数量算高度）
- 优势：少量候选一目了然，零滚动。
- 劣势：插件返回很多（AppLauncher 50 个）时面板撑满屏幕；仍需上限+滚动兜底，等于绕回混合。

**方案 C：混合阈值**（≤ T 全展示，> T 封顶 + 滚动）✅ 选定
- 优势：少量全展示（解决用户 8 个痛点）、多量自动滚动（兜底任意数量）；`min(count,T)` 单一公式统一两态，无分支。
- 劣势：需定 T；T 边界处面板高度有一次跳变（但每查询候选数确定，非中途切换，用户认可可接受）。

### 维度二：阈值 T

- T=10（覆盖 8 + 余量）／ T=8（恰好 case）／ 按屏幕高度动态（最充分利用屏幕但实现繁、面板随屏幕变）。✅ 选定 **T=8**。

### 维度三：修复范围

**方案 A：通用修复（所有候选区）** ✅ 选定
- 四处 `panelHeight` 的 `min(count,5)` → `min(count,8)`；各候选视图包 ScrollView+scrollTo。根因修复，所有插件受益。
- 劣势：surface 更大（需改 plugin/commandRoute/instant/lastRoute 四类候选视图 + panelHeight）。

**方案 B：仅 pluginCandidates 通道**（snip 路径）
- 优势：blast radius 最小。
- 劣势：instant/commandRoute 超 8 时同样裁切+不可达 bug 仍在，留已知遗留缺陷。排除。

## 选择与理由

**选定**：方案 C 混合阈值 + T=8 + 通用修复（所有候选区）。

**选择理由**：
- 混合 + T=8 直接解决用户"8 个看不到第 6-8"的痛点（≤8 全展示），同时 >8 自动滚动兜底任意数量；`min(count,8)` 单一公式无分支，符合用户"不复杂"判断。
- 通用修复是根因修复——同一 bug 同一修法，避免给 instant/commandRoute 留已知遗留。
- 实现路径已定且确定：候选视图包 `ScrollView` + `ScrollViewReader`、选中变化 `scrollTo`、`panelHeight` 阈值 5→8。无架构抉择。

**被排除方案及原因**：
- 纯滚动固定视口：用户明确想少量时全看到，固定 5 行仍需滚动看 6-8，不解决核心诉求。
- 全展示无上限：多候选场景面板失控，仍需兜底，绕回混合。
- 仅 pluginCandidates：留已知遗留缺陷，不符合根因系统性解决原则（[[root-cause-before-fixes]]）。
- 按屏幕高度动态 T：实现繁、面板高度随屏幕变，用户选择固定 T=8。

## 待主 SKILL 接力的设计决策

**已确认决策**：
1. 交互=混合阈值；T=8；范围=通用（plugin/commandRoute/instant/lastRoute 四候选区）。
2. 实现=候选视图包 `ScrollView`+`ScrollViewReader`，选中变化 `scrollTo(选中行 id, anchor: .center)`；`panelHeight` 四处 `min(count,5)` → `min(count,8)`。

**需要在设计文档中深化的点**：

1. **候选视图清单**（逐个包 ScrollView+scrollTo，设计文档须枚举全）：
   - `LauncherPluginCandidateView.swift:16-38`（pluginCandidates 通道，ForEach `id: \.element.id`，scrollTo 用 candidate.id 稳定）
   - `LauncherInstantCandidateView`（instant 通道）
   - `LauncherCandidateView`（commandRoute 通道）
   - lastRoute/aiRoute 候选渲染视图（设计文档定位确认）
   - 每个 ScrollView `.frame(height: min(count,8) * rowHeight)` 封顶（否则 ScrollView 撑开=全显示=裁切复现）。

2. **panelHeight 一致性契约**（关键）：ScrollView frame 高度必须与 `panelHeight` 的 `min(count,8)*44` 严格一致，否则要么裁切复现、要么留空白。注意 `panelHeight` 用字面量 `44`，行高用 `LauncherConstants.candidateRowHeight`——设计文档统一用常量消除魔数。

3. **scrollTo 触发点**：`navigateUp/navigateDown`（`LauncherInputView.swift:347-428`）改完 index 后触发；SwiftUI 走 `.onChange(of: selectedIndex)` 调 `proxy.scrollTo`。环形导航（末↓回首）时 scrollTo(0) 跳顶，自然成立。

4. **panelHeight 四处改点**：line 647（pluginCandidateExtra）、653（commandRouteExtra）、654（instantExtra）、662（lastRoute effectiveCount）。`5` → `8`，或抽 `LauncherConstants.candidateVisibleMax` 常量。

5. **测试盲区补齐**（现有测试全 ≤5 项，无覆盖）：
   - 8 项：面板高度=8 行全展示、无滚动、键盘到第 8 仍可见。
   - >8 项（造 10+ 候选）：面板封顶 8 行、键盘下移到第 9 时第 9 滚入可视区、选中高亮可见。
   - 环形：末项↓回首项，视图跳顶。
   - in-process XCTest 驱动（CLAUDE.md 能力 1，读 view 树断言选中行可见性 / panelHeight 值）。

6. **真机 E2E 验证**（CLAUDE.md QA 铁律，headless 有盲区）：`SKIP_FETCH_PLUGINS=1 make bundle` → 启动 → launcher 输 snip → 键盘↓到第 6/9 项 → 确认滚入可视 + 选中高亮可见。`buddy launcher debug candidates snip` 可造候选数据但滚动行为须真窗口观察。

7. **参考实现**：`SnipPanelVC.swift:240` 的 `tableView.scrollRowToVisible` 是 AppKit 同语义对照（非直接复用，SwiftUI 走 ScrollViewReader）。

8. **YAGNI 边界**：不做阈值可配置（launcher.json 调 T）、不做按屏幕动态高度——固定 T=8。
