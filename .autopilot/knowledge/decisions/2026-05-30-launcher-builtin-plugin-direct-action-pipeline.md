# launcher 内置插件：直接动作管线（绕过 LLM）+ BuiltinPlugin 协议 + 跨 plugin priority 仲裁

<!-- tags: launcher, builtin-plugin, architecture, direct-action, llm-bypass, in-process, plugin-protocol, registry, priority-arbitration, app-launcher, raycast, alfred, extensibility, nsworkspace -->

**决策**: launcher 既有插件全是外部 CLI 子进程，且每个 query 走一次 AI 往返。新增「内置插件」时**不复用**该模型，而是引入一条与 AI-agent **并列的原生 in-process 直接动作管线**：

- **直接动作而非 LLM 工具**：「搜索打开 app」是确定性意图（输入 saf → 启动 Safari），走 LLM 有延迟/token 成本/可能选错。改为 keyword/fuzzy 同步出候选 + Enter 直接 `NSWorkspace.open`（live 边打边搜 debounce 120ms，无内置匹配才落回 AI 流）。
- **可扩展协议**：`@MainActor protocol BuiltinPlugin { id; priority; sectionTitle; actions(for:) async -> [LauncherAction] }` + `BuiltinPluginRegistry` 聚合。加第二个插件（计算器/剪贴板）= 实现协议 + 注册，零侵入 LauncherManager。首个实现 AppLauncherPlugin 三层解耦：AppMatcher(纯函数 fuzzy) + AppIndex(内存索引 TTL 后台刷新) + AppLaunching(注入 seam，测试不真启动)。
- **跨 plugin「都命中」仲裁**：异构插件的 score **不可比**（app 的 fuzzy 分 vs 计算器的"=4"）。用 `(plugin.priority↓, action.score↓, title 字典序)` 全局排序 + 截断，**不硬抑制**——解释器型（高 priority）自然置顶，UI 按来源分小节。不做归一化全局混排。
- **@MainActor 全程**：live 管线（搜索内存级 <5ms）全在主线程，规避 NSImage/闭包跨 actor 的 Sendable 问题；后台扫盘用 Task.detached 扫完 hop 回 MainActor 替换 entries。

**理由**: 用户诉求是「架构和扩展性」。直接动作给零延迟原生体验；协议抽象让内置能力可无限扩展且与外部 CLI 插件、AI 对话三者清晰分层共存。

**约束**: 内置插件不得触碰像素猫子系统（Scene/Session/EventBus）；`perform: () throws -> Void` 上抛失败由 LauncherManager 捕获呈现（不静默吞错）；只实现 app 启动一个插件，协议为未来预留但不预写其他插件（YAGNI）。
