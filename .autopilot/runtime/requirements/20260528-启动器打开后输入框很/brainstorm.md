## 探索的目的与约束

**用户目标**：把桌面 app 的 Launcher（⌃Space 召唤的浮窗输入面板）重做成 Alfred 风格的大输入框 + 候选下拉，整体视觉对齐 `apps/web/` 站点的像素风（Web 已落地的设计 token：sage 主色、硬边像素阴影、pixel-border、Geist 字体族）。

**项目上下文（主 SKILL 已 prepass）**：
- 当前 Launcher = NSPanel 600×80→600×600，SwiftUI 内 18pt TextField + 8v padding（"很小、不可用"），背景 `.regularMaterial` 毛玻璃，无任何品牌色。
- 已存在快照测试（`apps/desktop/tests/BuddyCoreTests/Launcher/__Snapshots__/`，3 个 InputView 基线 + 3 个 CandidateView 基线），重设计会导致基线失效，需重录。
- 已存在 acceptance 测试 + 行为流（hotkey → submit → router 选 plugin → AgentEvent stream → markdown 渲染）保持完整工作。
- LSUIElement app + nonactivatingPanel + NSApp.activate 浮窗机制已就位（[2026-05-26 pattern]）。
- Web token 全量在 `apps/web/src/app/globals.css`，Light/Dark 双主题。

**约束**：
- 不动行为流，只换 UI（输入/候选/输出三段的视觉 + 输入框尺寸）。
- 中文首选（输入提示用中文）。
- 桌面侧需把 Web CSS token 翻译为 SwiftUI `Color` / `Font` / `Shape`，建立 Swift 端的 design tokens 文件作为唯一来源。
- 快照基线需重录，但 acceptance 测试逻辑不变。

## 候选方案与权衡

### 方案 A：Alfred 标准布局 + Web 像素装饰 + 跟随系统主题（**选定**）

- 面板尺寸 720×90（空态）→ 720+候选动态高，对齐 Alfred 5 默认。
- 输入框 28pt 系统字体（中文可读），padding 16-20px。
- 候选 row 44px，icon + name + desc，选中态 sage 主色填充 + paper 反白文字。
- 面板外观：圆角 + pixel-border 2px（ink/border-pixel）+ pixel-shadow 4px 硬偏移阴影（无 blur）。
- 跟随 NSAppearance：Light 用 web Light token（canvas #f7f6f1 / sage #3a7d68 / ink #1a1a18），Dark 用 web Dark token（canvas #0f0f0e / primary #52a688 / border-pixel #edece7）。
- 装饰像素字体（Geist Mono）只用在 badge、快捷键提示、底部脚注；正文与输入用系统字体保中文体验。
- 输出区与候选一起重做（统一 token、统一边距、统一选中/hover）。

**优势**：与 web 品牌强一致；中文输入体验不打折；macOS 原生主题习惯被保留；像素装饰范围可控、不"廉价"。
**劣势**：6 个快照基线需要重录；要新增 Swift 端 `LauncherTheme.swift` token 桥接层；面板尺寸变大可能影响小屏（13" Mac mini display ~1280×800 仍能 fit）。

### 方案 B：Alfred 暗色毛玻璃（被排除）

- 固定 dark + Alfred 默认毛玻璃，sage-light 高亮。
- **被排除原因**：用户 P0-1 未选"暗色毛玻璃外观"，且与 web 品牌（paper + sage）方向不一致。

### 方案 C：极简单行（被排除）

- 不加候选/不加装饰，只放大输入框。
- **被排除原因**：用户 P0-1 同时选了"候选 + 流式输出区分"，明确要三态分层。

## 选择与理由

**选定方案 A**。理由：

1. 满足 P0-1：三态分层（空 / 候选 / 输出）= "大输入框 + 候选 + 输出区分"的联合选项。
2. 满足 P0-2：装饰为主，正文系统字体——中文输入无副作用。
3. 满足 P0-3：跟随系统主题——和 macOS 用户习惯对齐，避免在亮屏强制暗主题。
4. 满足 P0-4：28pt + 720×90 = 接近 Alfred 5 默认值，是"够大但不夸张"的中位档。
5. 满足 P1：sage 填充高亮 + 完整 pixel-border/shadow 装饰 + 输出区一起重做。

**被排除**：B（暗主题固定）、C（极简单行）、L 角 pixel-corners（panel 太小会显得拥挤）。

## 待主 SKILL 接力的设计决策

下列已由用户确认，主 SKILL 写设计文档时直接采纳：

1. **三态自适应面板高度**：
   - 空态：720×90（仅输入框）
   - 候选态：720×(90 + n×44)，最多 6 候选 = 90+264 = 354
   - 输出态：720×(90 + 已选候选 44 + 输出区 max 400) = 最大约 720×534
   - 用 `NSPanel.setContentSize` + `animator()` 做高度平滑过渡

2. **尺寸常量**：
   - panelWidth = 720（原 600 → 720，需更新 `LauncherConstants.windowWidth`）
   - inputHeight = 64（含 padding）
   - inputFontSize = 28pt（系统字体，semibold 可选）
   - inputPadding = horizontal 20, vertical 16
   - candidateRowHeight = 44
   - candidateMaxRows = 5（保持 `routerMaxCandidates`）
   - outputMaxHeight = 400（保持现状）

3. **Swift 端 design tokens 桥接（新增文件 `LauncherTheme.swift`）**：
   - `enum LauncherTheme`：Color 静态属性按 light/dark 双套提供
   - Color：canvas, surface, surfaceAlt, ink, charcoal, smoke, primary (sage), primaryHover, mist, amber, vermillion, borderPixel
   - Font：bodyText（系统 28pt）、candidateName（系统 14pt medium）、candidateDesc（系统 12pt）、badgeMono（Geist Mono fallback 系统 mono 10pt uppercase）、footerMono（同 badgeMono 9pt）
   - Shadow：pixelShadowSm(offset 2,2)、pixelShadow(3,3)、pixelShadowLg(4,4)，硬阴影无 radius
   - Border：pixelBorderWidth = 2, panelCornerRadius = 14

4. **候选选中态**：
   - 背景：sage primary 填充（Light: #3a7d68 / Dark: #52a688）
   - 文字：paper 反白（Light: #f7f6f1 / Dark: ink #1a1a18 — 视对比度调）
   - badge "WEATHER" 等 plugin name 用 Geist Mono 10pt uppercase + 反白色

5. **面板外观**：
   - 圆角 14px
   - pixel-border 2px solid（ink / border-pixel）
   - pixel-shadow 4px (right + bottom 偏移，无 blur)
   - 不要 L 角 pixel-corners（保持简洁）
   - 替换 `.regularMaterial` 为 token surface 色（不再毛玻璃）

6. **输出区一并重做**：
   - 背景：surface（与输入区不同色，做出区段分隔）
   - 顶部分隔：1px hairline ink/border-pixel（不是 pixel-border 2px，避免重复）
   - markdown 文本：系统字体 14pt body + code block 用等宽 + sage 链接色
   - ScrollView max 400 保持

7. **微动效**（轻量）：
   - 候选展开/收起：250ms ease-out 高度过渡
   - 选中 row 跟随键盘 ↑↓：50ms 高亮跳转
   - 按下提交：sage 主色短暂 flash（150ms）
   - 不做 Alfred 那种渐入渐出（避免 NSPanel level 切换抖动）

8. **测试基线更新**：
   - 6 个现有快照基线（3 InputView + 3 CandidateView）需重录
   - acceptance 测试逻辑保留，仅可能调整 frame 期望值（如断言 panel.frame.size.width == 720）
   - 新增至少 1 个"selected candidate has sage background"快照专项

9. **契约（contract_required=true）**：
   - LauncherTheme 公开属性签名（颜色名 / 字体名 / 阴影名）作为契约
   - Panel 尺寸常量（panelWidth=720, inputHeight=64 等）作为契约
   - 三态高度公式（empty=90, withCandidates=90+n×44, withOutput=…）作为契约
   - 选中态视觉契约：选中 row 的 background = LauncherTheme.primary（不允许在 view 里 hardcode 颜色）

10. **范围红线**：
    - 不动 LauncherRouter / LauncherManager / LauncherAgent / 热键注册
    - 不动 acceptance 测试断言（除可能的 frame 尺寸）
    - 不引入新的 SPM 依赖（Geist Mono 字体走系统等宽 fallback，不内嵌 woff2 到 bundle）
    - 不做 dark mode 切换 UI（跟随系统即可）
