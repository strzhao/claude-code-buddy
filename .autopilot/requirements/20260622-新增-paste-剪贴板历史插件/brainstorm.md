# Brainstorm — 新增 paste 剪贴板历史插件（标准内置插件 + app 常驻监听）

## 探索的目的与约束

**目标**：给 buddy app 新增**剪贴板历史管理**功能（参考 Alfred / Maccy / Raycast），以**标准内置插件**形态实现：用户在 Launcher 浮窗输入触发词唤起历史候选列表，选中后写入系统剪贴板供用户 ⌘V 粘贴。

**架构核心（用户二次澄清后定稿）**：

- **交互层 = 标准内置插件**：plugin.json + 可执行体，放在 `Marketplace/plugins/paste/`，走 marketplace `local-subdir` source 分发，与 `qr` / `hello` / `translate` / `qzh` **完全同形态**。走完整插件协议（manifest + 候选机制 + TOFU 信任）。
- **常驻监听层 = app 内部**：`ClipboardHistoryService`（常驻轮询 `NSPasteboard.changeCount` + 写历史文件）。**插件是非常驻子进程**，无法承担持续监听，所以监听只能在 app。
- 两层通过**历史文件**解耦：app 写 `~/.buddy/clipboard-history.json`，插件读它输出候选。

> 原始需求措辞「使用社区插件方案实现」**成立**——交互层确实走插件协议。最初的矛盾（「插件非常驻无法监听」）通过「监听层下沉到 app、交互层仍是插件」化解，而非推翻插件方案。

**项目上下文探索关键发现**：

1. **「社区插件方案」= Launcher CLI 插件机制**（`apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Plugin/`）：三种模式 `stdin` / `prompt` / `command`，`plugin.json` manifest，marketplace 分发（`MarketplaceManager`），TOFU 信任（`TrustStore`），GitHub 安装。**插件是按需触发的子进程**——召唤才起、用完即销，退出后无法继续监听剪贴板变化。
2. **内置插件就是 bundle 在 app 里的标准插件**：`qr` / `hello` / `translate` / `qzh` 都在 `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/<name>/`，通过 seed `marketplace.json` 的 `local-subdir` source 在首启时拷到 `~/.buddy/launcher-plugins/`（见 `.autopilot/project/design.md` 的 Marketplace 重构设计）。**paste 插件与它们同形态**，不是特殊机制。
3. **`qr` 是 command 模式 + swift 编译 binary 的活样本**（`qr-gen.swift` → universal binary，输出 PNG 到 `BUDDY_OUTPUT_IMAGE`）——paste 插件的执行体可照此实现（swift binary，能完整操作 NSPasteboard）。`qzh` 是 command 模式 + 候选输出（`BUDDY_OUTPUT_CANDIDATES`）+ selection 回传的活样本——paste 的「列表 → 选中」交互照此。
4. **候选协议**：候选 JSON 格式 `[{"id":"","title":"","selection":""}]`；用户选中后 Launcher 把 `selection` 回传给插件二次调用（`StdinExecutor` / `PluginDispatcher`，输入 JSON 含 `selection` 字段）。
5. **现有剪贴板能力只有「写」无「读」**：`Launcher/Service/CopyService.swift` 提供 `copy(_ text:)` / `copyImage(_ data:)`（单例 + 可注入测试 pasteboard）。**没有读取 / 监听 NSPasteboard 的能力**。注意：CopyService 在 app 进程内，插件子进程**不能直接调**——插件写剪贴板须在自己的进程内用 NSPasteboard API（swift binary）。
6. **Launcher app 是常驻 LSUIElement menubar app**——具备挂常驻监听服务的前提（Alfred/Maccy/Raycast 的标准做法：轮询 `NSPasteboard.general.changeCount`）。
7. **`~/.buddy/` 目录是纯文件风格**（`marketplace.json`、`launcher-plugins/`、`launcher-trust.json`、`launcher-sync.log`）——JSON 持久化与之契合。
8. **候选点击交互**有 knowledge pattern `lsuielement-nscollectionview-sendevent-click`（menubar agent 窗口非 key window，需 sendEvent 拦截点击）。

**明确约束**：

- **交互层走标准内置插件协议**：plugin.json + 可执行体 + marketplace `local-subdir` 分发 + TOFU 信任，与 `qr`/`hello`/`translate` 同形态。**不造特殊的「内置候选源」机制**——现成插件协议就是扩展点（架构正交性元原则）。
- **常驻监听在 app 内部**：`ClipboardHistoryService` 常驻，插件只读历史文件、不负责监听。
- **零额外权限**：选中后写入系统剪贴板（插件进程内 NSPasteboard API），浮窗提示「已复制」，**不模拟 ⌘V**（避开 accessibility 权限 / TCC 弹窗，参考 knowledge pattern `ghostty-applescript-tcc-second-layer`）。
- **安全硬约束（不可商量）**：必须排除 `org.nspasteboard.ConcealedType`（密码管理器标记）和 `org.nspasteboard.TransientType`（临时内容）的条目——否则记录密码造成泄露。
- **全内容类型**：纯文本 + 图片(PNG) + 文件路径(`public.file-url`) + 富文本(HTML，附纯文本 fallback)。

## 候选方案与权衡

本次探索逐项澄清了 4 个独立维度，每项均经 AskUserQuestion 用户决策；维度 1 经用户二次澄清修正：

### 维度 1：架构分层（剪贴板历史需常驻监听 vs 插件是按需子进程）

- A. 混合：监听在 app、交互在插件
- B. 纯插件 + 单次快照（无历史）
- C. 独立常驻后台 daemon
- D. 全部 app 内部实现（不走插件）
- ✅ **修正后选定 = 维度 1 的 A**：**app 内部常驻监听 + 标准内置插件交互层**。用户二次澄清强调「即使是内置，交互层也必须走标准插件协议，仍然是插件」——即 A 而非 D。

### 维度 2：内容类型（决定存储结构与空间成本）

- 纯文本 / 图片 / 文件路径 / 富文本-HTML —— **用户全选** ✅，存储结构须多类型。

### 维度 3：入口与交互形态（决定产品形态与工作量）

- ✅ **A. 集成进 Launcher 浮窗** —— 输入触发词（`cb` / `剪贴板`）路由到 paste 插件，复用现有候选渲染与键盘导航。加法式、工作量适中。
- B. 独立快捷键 + 专属面板（Maccy 式）—— 最正统但独立窗口/快捷键工作量最大。
- C. Launcher 顶部 tab 入口。

### 维度 4：存储与集成方案（决定持久化与查询机制）

- ✅ **A. JSON 持久化** —— 内存数组 + 落盘 `~/.buddy/clipboard-history.json`，图片存 `~/.buddy/clipboard-images/<sha8>.png`，sha256 去重。插件读 JSON 输出候选。
- B. SQLite + 独立 Provider —— 查询高效但 schema 迁移/并发复杂，对该规模偏过度设计。
- C. 纯内存（重启清空）—— 不符合跨重启预期。

## 选择与理由

**选定方案**：维度 1=A（app 监听 + 标准内置插件交互）× 维度 2=全类型 × 维度 3=A（Launcher 集成）× 维度 4=A（JSON 持久化）。

**架构分层（修正后）**：

```
┌──────────────────────────────────────────────────┐
│ app 内部（常驻）                                   │
│  ClipboardHistoryService                          │
│   - Timer 0.5s 轮询 NSPasteboard.changeCount      │
│   - 多类型读取 + ConcealedType/TransientType 排除  │
│   - sha256 去重（回填触发的变化靠此化解循环）       │
│   - 写 ~/.buddy/clipboard-history.json            │
│       + ~/.buddy/clipboard-images/<sha8>.png      │
└──────────────────────────────────────────────────┘
                  ↑ 插件读历史文件（解耦）
┌──────────────────────────────────────────────────┐
│ 标准内置插件（按需触发，完整插件协议）               │
│  Marketplace/plugins/paste/                       │
│   ├ plugin.json (mode: command)                   │
│   └ paste-exec (swift binary, 类 qr-gen)          │
│      - 无 selection: 读 JSON → 输出候选列表        │
│      - 有 selection: 按 id 在进程内写 NSPasteboard │
│        (文本/图片 PNG/文件 URL/HTML)               │
└──────────────────────────────────────────────────┘
                  ↑ 触发词路由 (cb / 剪贴板)
              Launcher 浮窗候选渲染
```

**选择理由**：

- **A（app 监听 + 内置插件交互）**：插件非常驻无法监听，所以监听层必须下沉 app；但交互层**正经走标准插件协议**，复用 manifest / 候选机制 / TOFU / marketplace 分发，零新机制（架构正交性）。这也契合用户偏好「产品感优先、原生正统形态」——标准插件就是 Launcher 的正统扩展形态。
- **A（Launcher 集成）而非 B（独立面板）**：复用现有候选渲染、键盘导航、触发词路由，加法式、风险低。
- **A（JSON）而非 B（SQLite）**：与 `~/.buddy/` 纯文件风格一致、易调试、YAGNI 友好；插件读 JSON 文件比读 SQLite 简单（无需 DB 驱动依赖）。
- **仅写入剪贴板（不模拟 ⌘V）**：零权限、简单可靠，避开 accessibility/TCC 坑。

**被排除方案及原因**：

- 「全部 app 内部、不走插件」（维度 1 的 D）：用户二次澄清否决——交互层必须走标准插件协议。
- 「特殊内置候选源机制」：造新机制违反架构正交性，标准插件协议已够用。
- SQLite（B-存储）：对当前规模过度设计，且插件读 SQLite 需额外依赖。
- 独立面板（B-入口）：工作量过大，复用 Launcher 更符合加法式。
- 模拟 ⌘V 回填：引入 accessibility 权限依赖与 TCC 坑，收益不抵成本。

## 待主 SKILL 接力的设计决策

以下为已确认决策 + 需在设计文档深化的关键点（路标，非最终方案）：

### 已确认决策（设计文档须遵循）

1. **交互层 = 标准内置插件**：`Marketplace/plugins/paste/`（plugin.json + swift 可执行体），走 marketplace `local-subdir` 分发，与 `qr`/`hello`/`translate` 同形态。**完整走插件协议**（manifest + 候选 + TOFU）。
2. **常驻监听 = app 内部 `ClipboardHistoryService`**：常驻轮询 changeCount + 写历史文件，插件不参与监听。
3. **全内容类型**：纯文本 + 图片(PNG) + 文件路径(`public.file-url`) + 富文本(HTML + 纯文本 fallback)。
4. **入口**：Launcher 浮窗触发词路由（`cb` / `剪贴板`），复用现有候选列表 + 键盘导航。
5. **回填**：插件收到 selection 后，在**插件进程内**用 NSPasteboard API 写对应类型 → 浮窗「已复制」→ 关闭浮窗。**不模拟 ⌘V**。
6. **存储**：JSON 落盘 `~/.buddy/clipboard-history.json` + 图片文件 `~/.buddy/clipboard-images/<sha8>.png`，app 端内存数组为主、增量落盘。
7. **安全排除**：`org.nspasteboard.ConcealedType`（密码）+ `org.nspasteboard.TransientType`（临时）一律不记录。

### 设计文档需深化的点

1. **`ClipboardHistoryService` 生命周期与监听实现**（app 内部）：
   - 在哪初始化（AppDelegate `applicationDidFinishLoading` 或 Launcher 子系统初始化点）。
   - 监听机制：`Timer`（建议 0.5s）轮询 `NSPasteboard.general.changeCount`，变化时读取。**NSPasteboard 无可靠 change 通知**，轮询是行业标准。
   - 功耗：0.5s vs 1s 间隔取舍（参考 knowledge pattern `smoothturn-display-link-availability` 的 timer 心得）。

2. **NSPasteboard 多类型读取的正确姿势**（app 端监听写入）：
   - 优先级判定：`ConcealedType` / `TransientType` 在前（排除）→ `public.file-url`（文件路径）→ `public.png`（图片）→ `public.html`（富文本，附 `public.utf8-plain-text` fallback）→ 纯文本。
   - 单次 changeCount 变化可能同时含多类型，按优先级取主类型记录。
   - sourceApp（可选）：`NSWorkspace.shared.frontmostApplication` 记录来源 app，便于后续黑名单（YAGNI，先记录不实现黑名单）。

3. **存储 schema（JSON）**：
   ```json
   {
     "schemaVersion": 1,
     "items": [
       {"id":"<uuid>","type":"text|image|file|html","content":"...","html":"...(仅html)","path":"~/.buddy/clipboard-images/<sha8>.png(仅image)","sourceApp":"com.apple.Terminal","ts":1719000000,"hash":"<sha8>"}
     ]
   }
   ```

4. **去重策略**：sha256 内容 hash——文本 hash 字符串、图片 hash PNG data、文件路径 hash 路径、富文本 hash 纯文本。**连续重复只更新 ts 不新增**；非连续重复（历史已有但非最近）提至队首（符合「最近使用」直觉）。**关键**：插件回填写入剪贴板会触发 changeCount 变化，靠此去重化解「回填即重复记录」循环。

5. **paste 插件实现（command 模式 swift binary，参考 `qr-gen.swift`）**：
   - plugin.json：`mode: command`、`cmd: ./paste-exec`、`keywords: ["paste","cb","剪贴板","clipboard"]`、`timeout: 5`。
   - 无 selection 调用：读 `~/.buddy/clipboard-history.json` → 按类型渲染候选 title（文本截断、图片标 [图片]、文件标路径、富文本标 [富文本]）→ 输出候选 JSON 到 `BUDDY_OUTPUT_CANDIDATES`。
   - 有 selection 调用：按 id 查历史项 → 在插件进程内写 NSPasteboard（文本 `setString`、图片 `setData(png)`、文件 `writeObjects([NSURL])`、富文本同时写 html+string）→ stdout 输出「✅ 已复制」markdown。
   - 文件路径获取：历史文件路径通过环境变量或固定 `~/.buddy/clipboard-history.json` 约定（app 与插件共享路径约定）。

6. **回填循环验证**：插件写剪贴板 → app 监听到 changeCount 变化 → sha256 命中已有条目 → 提至队首不新增。设计须明确此路径，避免回填产生重复。

7. **限制与过期**：文本 500 条 / 图片 50 张 / 30 天过期。清理时机：app 启动时全量清理 + 每次写入后增量裁剪。

8. **测试策略**：
   - app 端 `ClipboardHistoryService`：注入具名 `NSPasteboard` + 临时存储目录（参考 `CopyService.init(pasteboard:)` 的可注入模式、knowledge `urlprotocol-mock-httpbodystream-canonical-request`）。
   - 插件端 `paste-exec`：喂 fixture JSON 验证候选输出 + selection 回传写剪贴板（注入测试 pasteboard）。
   - 参考 knowledge `swift-test-filter-skips-spritekit` 的测试过滤。

9. **E2E 验证（硬要求，参考 memory `feedback_qa-e2e-verification`）**：必须启动 app 真实复制粘贴端到端验证——复制文本/图片/文件/富文本各一条 → Launcher 输入 `cb` 看到 paste 插件候选 → 选中 → 验证写入剪贴板（⌘V 到文本框确认）。另单独验证：① 密码排除（复制 1Password 内容不被记录）；② 回填不产生重复历史条目。

10. **YAGNI 明确不做**：app 黑名单、分类分组 UI、fuzzy 搜索增强、标签/收藏、跨设备同步、专用快捷键（复用 Launcher 召唤 + 触发词即可）。如未来需要，JSON schema 已留 `schemaVersion` 演进出口。

### 相关 knowledge / memory 路标

- memory `feedback_qa-e2e-verification`（QA 必须真实 E2E）
- memory `feedback_product-sense-over-features`（原生正统形态优先——本决策依据）
- memory `feedback_lsuielement-window`（Launcher 浮窗 key window 交互）
- knowledge `lsuielement-nscollectionview-sendevent-click`（候选点击 sendEvent）
- knowledge `launcher-router-shortcircuit-unique-match` / `launcher-instant-command-candidate-mutual-exclusion`（路由接入）
- knowledge `ghostty-applescript-tcc-second-layer`（TCC 坑——回填不模拟 ⌘V 的依据）
- knowledge `app-embedded-cli-homebrew-binary-path`（app 内嵌 binary 路径约定，paste-exec 打包参考）
- knowledge `spm-bundle-module-app-package-path` / `spm-bundle-module-crash-custom-replacement`（swift binary 打包进 bundle，qr-gen 的做法参考）
