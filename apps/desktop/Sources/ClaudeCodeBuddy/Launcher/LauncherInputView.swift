import SwiftUI

struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    @State private var query: String = ""
    @State private var outputBuffer: String = ""            // 流式累积 markdown 原文
    @State private var actions: [LauncherActionButton] = []  // 模型声明的 render-only 按钮（底部工具条）
    @State private var errorOutput: AttributedString?       // 仅用于 .error 路径
    @State private var resultImage: NSImage?                // 图片通道：渲染用（PNG → NSImage）
    @State private var resultImageData: Data?               // 原始 PNG 字节（场景3.P2：点击复制保持字节一致，不经 NSImage 重编码）
    @State private var copied: Bool = false                 // 图片点击复制反馈（✓，1.2s 复位）
    @State private var copiedResetTask: Task<Void, Never>?  // 复位 copied 的 Task（取消旧的重置）
    @State private var visible: Bool = false                // 入场动画状态（C6 契约）
    /// 候选输出通道（C1）：command/stdin mode 子进程产的候选列表，用户选中触发 submitWithCandidate 回调（C5）。
    @State private var pluginCandidates: [LauncherCandidate] = []
    /// 候选列表选中索引（↑↓ 导航 + Enter 选中，复用 lastRouteSelectedIndex 风格的本地态）。
    @State private var pluginCandidateIndex: Int = -1
    /// 回调重入时保留的原始 query + manifest（C5：选中候选后用同 query 重入同插件）。
    @State private var callbackQuery: String = ""
    @State private var callbackManifest: PluginManifest?
    @FocusState private var focused: Bool

    /// 派生自 manager.stage（不再维护独立 @State isRunning）
    private var isRunning: Bool {
        manager.stage != .idle && manager.stage != .error
    }

    /// 是否有可见输出（正文非空 or 有错误输出 or 有图片 or 有插件候选）
    private var hasOutput: Bool {
        !outputBuffer.isEmpty || errorOutput != nil || resultImage != nil || !pluginCandidates.isEmpty
    }

    /// 统一混排候选区（D6：单列表，app + 内置 + 社区插件同一列表）是否显示：
    /// safe period 且无结果展示；C-PARAM-ISOLATE：参数态（lockedCommand != nil）隐藏。
    private var showInstantCandidates: Bool {
        guard !hasOutput else { return false }
        guard manager.lockedCommand == nil else { return false }
        return manager.stage == .idle || manager.stage == .narrowing || manager.stage == .routing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 输入区（固定 inputHeight=64，让 TextField 内 SwiftUI 自动垂直居中）
            HStack(spacing: 8) {
                ZStack(alignment: .trailing) {
                    TextField("搜索插件、运行命令、或直接提问…", text: $query)
                        .textFieldStyle(.plain)
                        .font(LauncherTheme.bodyText)
                        .foregroundStyle(LauncherTheme.ink)
                        .padding(.horizontal, LauncherConstants.inputPaddingH)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focused($focused)
                        .disabled(isRunning)
                        .onSubmit { Task { await submit() } }
                        .onChange(of: query) { _, new in
                            if new.count > LauncherConstants.maxQueryLength {
                                query = String(new.prefix(LauncherConstants.maxQueryLength))
                            }
                            // task 011：即时候选管线 — 每次输入变化触发 debounce 搜索
                            // updateQuery 内部已经维护 lastRoutePluginName（chip 信号源）
                            // 不在这里清 segments — 让 .done 后 query="" 不会瞬间擦掉结果
                            manager.updateQuery(new)
                        }

                    // 锁定态显示「已锁定」chip（D5，C-TAB-LOCK 视觉反馈；watermark chip 已退役）
                    if let locked = manager.lockedCommand {
                        LockedCommandChip(name: locked.name)
                            .padding(.trailing, 14)
                    }
                }
            }
            .frame(height: LauncherConstants.inputHeight)

            // 统一混排候选区（D6：单列表承载 app/内置/社区插件全部候选）
            if showInstantCandidates && !manager.instantActions.isEmpty {
                LauncherInstantCandidateView(
                    actions: manager.instantActions,
                    // 单选高亮 + 滚动（typing 期恒 .instant，直接读 instantSelectedIndex）
                    // C-SCROLL-TO-SELECTION：selectedIndex 用 @Binding（B1 fallback）。
                    selectedIndex: Binding(
                        get: { manager.instantSelectedIndex },
                        set: { manager.setInstantSelectedIndex($0) }
                    ),
                    onRowTap: { action in
                        // D5/D6：点击行分流——插件行 = 锁定（≠ 执行，C-TAB-LOCK）；app/内置行 = 执行
                        guard let idx = manager.instantActions.firstIndex(where: { $0.id == action.id }) else { return }
                        manager.setInstantSelectedIndex(idx)
                        if manager.resolvePluginCandidate(pluginId: action.pluginId) != nil {
                            // 插件行：点击 = Tab 锁定语义
                            if let manifest = manager.resolvePluginCandidate(pluginId: action.pluginId) {
                                manager.lockPluginCandidate(manifest)
                                focused = true
                            }
                        } else {
                            // app/内置行：点击 = 执行（与 Enter 同义）
                            Task { await submit() }
                        }
                    }
                )
            }

            // 插件候选输出通道（C1）：command/stdin 插件返回的候选列表（如 qzh 的 stop/start）。
            // 用户 ↑↓ 选中 + Enter / 点击 → submitWithCandidate 回调（C5，执行权留插件）。
            if !pluginCandidates.isEmpty {
                LauncherPluginCandidateView(
                    candidates: pluginCandidates,
                    // C-SCROLL-TO-SELECTION：selectedIndex 用 @Binding（B1 fallback），$pluginCandidateIndex。
                    selectedIndex: $pluginCandidateIndex,
                    onSelect: { candidate in
                        // 点击候选：定位其索引后触发 submit（submit 内检测候选选中走回调）
                        if let idx = pluginCandidates.firstIndex(where: { $0.id == candidate.id }) {
                            pluginCandidateIndex = idx
                            Task { await submit() }
                        }
                    }
                )
            }

            // 底部状态栏（C5 契约）：仅 error 时显示「执行失败」；loading 态无任何状态文字
            LauncherStatusFooter(
                stage: manager.stage,
                pluginName: manager.lastRoutePluginName
            )

            // 接近上限时显示字数指示（warning UI）
            if query.count >= LauncherConstants.maxQueryLength - 1000 {
                Text("\(query.count) / \(LauncherConstants.maxQueryLength)")
                    .font(LauncherTheme.footerMono)
                    .foregroundStyle(query.count >= LauncherConstants.maxQueryLength
                                        ? Color.red : LauncherTheme.smoke)
                    .padding(.horizontal, LauncherConstants.inputPaddingH)
                    .padding(.bottom, 4)
            }

            // 输出区（有内容时显示）
            if hasOutput {
                // 输入行与结果区之间的极淡分隔（曾用系统 separatorColor，在毛玻璃上偏重突兀）。
                // 改为很淡的 ink hairline + 左右内缩留白，弱化为"气口"而非硬线。
                LauncherTheme.ink.opacity(0.06)
                    .frame(height: 1)
                    .padding(.horizontal, LauncherConstants.inputPaddingH)

                ScrollView {
                    if let errOut = errorOutput {
                        // 错误路径：单一 AttributedString
                        Text(errOut)
                            .font(LauncherTheme.outputBody)
                            .foregroundStyle(LauncherTheme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LauncherConstants.inputPaddingH)
                            .padding(.vertical, 12)
                    } else {
                        // 正常路径：正文走干净 markdown 连续渲染（按钮收在底部工具条）
                        // 图片通道（T6）：command/stdin mode 子进程产 PNG → 居中白底卡片展示，点击复制
                        VStack(spacing: 12) {
                            if let img = resultImage {
                                resultImageCard(image: img)
                            }
                            if !outputBuffer.isEmpty {
                                Text(MarkdownRenderer.render(outputBuffer))
                                    .font(LauncherTheme.outputBody)
                                    .foregroundStyle(LauncherTheme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, LauncherConstants.inputPaddingH)
                            }
                        }
                        .padding(.vertical, 12)
                        // 无图片且无文本时显示占位（降级，场景4.P2 错误占位 / 空输出）
                        .overlay {
                            if resultImage == nil && outputBuffer.isEmpty {
                                Text("未生成图片")
                                    .font(LauncherTheme.outputBody)
                                    .foregroundStyle(LauncherTheme.smoke)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: LauncherConstants.outputMaxHeight, alignment: .topLeading)
                // 不再盖不透明白底（曾用 LauncherTheme.surface=#fff，浅色下成生硬白方块 + 底部直角，
                // 遮住毛玻璃与圆角）。改为透明 → 结果区与输入行共用同一块毛玻璃，整面板连续、底部圆角自然。

                // 底部统一工具条：模型声明的 render-only 按钮（朗读/复制）。
                // 同样不盖 surface 白底，工具条直接落在共享毛玻璃上，与结果区保持连续。
                if errorOutput == nil && !actions.isEmpty {
                    LauncherActionBar(actions: actions)
                }
            }
        } // end VStack
        .frame(
            width: LauncherConstants.windowWidth,
            height: LauncherInputView.panelHeight(
                candidateCount: manager.lastRouteCandidates.count,
                hasSelected: false,
                outputHeight: (hasOutput && pluginCandidates.isEmpty) ? LauncherConstants.outputMaxHeight : 0,
                hasFooter: manager.stage == .error,
                instantCount: showInstantCandidates ? manager.instantActions.count : 0,
                pluginCandidateCount: pluginCandidates.count
            ),
            alignment: .top
        )
        // 视觉容器：NSVisualEffectView 毛玻璃（跟随 effectiveAppearance）+ innerHighlight 内边框。
        // 注：曾用 SwiftUI `.ultraThinMaterial`，但其 light/dark 依赖 @Environment(\.colorScheme)，
        // 在 NSPanel+hidesOnDeactivate 浮窗里传播不可靠 → 浅色模式毛玻璃停留深色发灰、与白色 surface
        // 错配（见 VisualEffectBackground 注释与 .autopilot/knowledge 2026-05-28 条目）。
        // 改用 NSVisualEffectView 包装，AppKit 直接按真实外观求值，浅/深色一致。
        // NSVisualEffectView 注入仍保留在 LauncherWindow 中作为 C1 红队契约的结构性兜底。
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                        .strokeBorder(LauncherTheme.innerHighlight, lineWidth: 1)
                )
        )
        // loading 态：边框单彗星流光（取代旧的右侧 pulse dots + "正在处理" 文案）。
        // 流光沿面板既有圆角边框路径流动，整圈只有一条边框线；loading 不再有任何状态文字。
        .overlay {
            if isRunning {
                LauncherLoadingBorder()
                    .accessibilityElement()
                    .accessibilityLabel("正在处理")
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isRunning)
        // 入场 spring 动效（C6 契约）
        .scaleEffect(visible ? 1.0 : 0.96)
        .opacity(visible ? 1.0 : 0.0)
        .onAppear {
            visible = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                visible = true
            }
            focused = true
            query = ""
            outputBuffer = ""
            actions = []
            errorOutput = nil
            resultImage = nil
            resultImageData = nil
            copied = false
            pluginCandidates = []
            pluginCandidateIndex = -1
            callbackQuery = ""
            callbackManifest = nil
        }
        // 二次召唤（panel orderOut 后再 makeKeyAndOrderFront）时 view 实例复用，
        // onAppear 不重触发；监听 isVisible false→true 清空上次的 query/output/segments
        .onChange(of: manager.isVisible) { _, isNowVisible in
            if isNowVisible {
                query = ""
                outputBuffer = ""
                actions = []
                errorOutput = nil
                resultImage = nil
                resultImageData = nil
                copied = false
                pluginCandidates = []
                pluginCandidateIndex = -1
                callbackQuery = ""
                callbackManifest = nil
                focused = true
            }
        }
        .onDisappear {}
        .onExitCommand { handleEscape() }   // Esc：分层（C-ESC-EXIT）—— lockedCommand 非空只清锁，否则 hide
        // 上下箭头键导航候选列表：instant（统一列表）优先，否则 lastRoute 兜底（C5 契约）
        .onKeyPress(.upArrow) { navigateUp() }
        .onKeyPress(.downArrow) { navigateDown() }
        // D5（C-TAB-LOCK）：统一列表选中行是插件 → Tab 锁定该插件（不执行）；app/内置行 Tab 忽略。
        .onKeyPress(.tab) {
            if manager.handleTabLock() {
                focused = true
                return .handled
            }
            return .ignored
        }
        // task 011 交互优化：emacs 键位 Ctrl-N（下）/ Ctrl-P（上）。
        // 用 phases:.down 的 catch-all 读 modifiers/key；非 Ctrl-N/P 一律 .ignored 让普通输入透传到 TextField。
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            switch press.key {
            case KeyEquivalent("n"): return navigateDown()
            case KeyEquivalent("p"): return navigateUp()
            default: return .ignored
            }
        }
        // ⌘, 打开设置（macOS 标准语义，调试便利）：launcher 输入框活跃时触发。
        // LSUIElement 无 mainMenu → 系统不拦截 ⌘, → onKeyPress 能收到。
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command), press.key == KeyEquivalent(",") else {
                return .ignored
            }
            (NSApp.delegate as? AppDelegate)?.showSettings(source: "launcher")
            return .handled
        }
    }

    // MARK: - Esc 分层（C-ESC-EXIT）

    /// Esc 分层处理：lockedCommand 非空 → 拦截只清 lockedCommand（保留输入框供改输）；nil → 维持 hide。
    private func handleEscape() {
        if manager.lockedCommand != nil {
            manager.clearLockedCommand()
            // 退出锁定后重新匹配当前 query（恢复候选态）
            manager.updateQuery(query)
        } else {
            manager.hide()
        }
    }

    // MARK: - 候选导航（箭头 / emacs Ctrl-N·P 共用）

    /// 向上移动选中：D6 简化三态派发。
    /// pluginCandidates 通道(post-exec) 隔离 → instant（统一列表，环形）→ aiRoute 兜底。
    /// C-PARAM-ISOLATE：参数态（lockedCommand != nil）候选区空，↑↓ 无效（忽略，让光标在输入框正常编辑）。
    private func navigateUp() -> KeyPress.Result {
        if manager.lockedCommand != nil { return .ignored }
        // C5：pluginCandidates 通道非空 → 仅区内环形，隔离其他区（既有短路保留）
        if !pluginCandidates.isEmpty {
            let count = pluginCandidates.count
            pluginCandidateIndex = (pluginCandidateIndex <= 0) ? count - 1 : pluginCandidateIndex - 1
            return .handled
        }
        // 统一列表：区内环形
        if !manager.instantActions.isEmpty {
            manager.moveInstantSelection(up: true)
            return .handled
        }
        // aiRoute 兜底（lastRouteCandidates）
        let count = manager.lastRouteCandidates.count
        guard count > 0 else { return .ignored }
        let current = manager.lastRouteSelectedIndex
        manager.setSelectedIndex((current <= 0) ? count - 1 : current - 1)
        return .handled
    }

    /// 向下移动选中：D6 简化三态派发（对称 navigateUp）。
    /// C-PARAM-ISOLATE：参数态（lockedCommand != nil）↑↓ 无效（忽略）。
    private func navigateDown() -> KeyPress.Result {
        if manager.lockedCommand != nil { return .ignored }
        if !pluginCandidates.isEmpty {
            let count = pluginCandidates.count
            pluginCandidateIndex = (pluginCandidateIndex >= count - 1) ? 0 : pluginCandidateIndex + 1
            return .handled
        }
        // 统一列表：区内环形
        if !manager.instantActions.isEmpty {
            manager.moveInstantSelection(up: false)
            return .handled
        }
        let count = manager.lastRouteCandidates.count
        guard count > 0 else { return .ignored }
        let current = manager.lastRouteSelectedIndex
        manager.setSelectedIndex((current >= count - 1) ? 0 : current + 1)
        return .handled
    }

    // MARK: - 图片展示卡片（T6）

    /// 居中白底 200pt 卡片（白底保证扫码对比度），点击 → CopyService.copyImage（PNG）+ ✓ 反馈（1.2s 复位）。
    /// 场景3.P1/P3：点击图片写 PNG 到剪贴板 + AX 可感知反馈。
    private func resultImageCard(image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.none)   // 像素艺术风格，二维码清晰
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .padding(12)
            .background(
                // 白底卡片：保证二维码扫码对比度（深色码点 + 白底）
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
            )
            .overlay {
                // ✓ 复制反馈（copied=true 时短暂显示）
                if copied {
                    Text("✓")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(LauncherTheme.selectionTint)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)   // 居中
            .contentShape(Rectangle())
            .onTapGesture {
                copyResultImage()
            }
            .accessibilityElement()
            .accessibilityLabel(copied ? "已复制图片" : "二维码，点击复制")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) {
                copyResultImage()
            }
    }

    /// 点击图片 → CopyService.copyImage(PNG data) + copied=true（1.2s 复位）。
    /// 场景3.P2：剪贴板 PNG 与原始字节一致。
    private func copyResultImage() {
        // 场景3.P2：用 AgentEvent.image 的原始 PNG 字节，不经 NSImage tiff→PNG 重编码，
        // 保证剪贴板字节 == BUDDY_OUTPUT_IMAGE（md5 一致）。resultImage 仅用于渲染。
        guard let png = resultImageData else { return }
        CopyService.shared.copyImage(png)
        // 取消旧的重置 Task，重新计时（连续点击不提前复位）
        copiedResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // 1.2s
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }

    private func submit() async {
        // D4 分流顺序（C-ENTER-EXEC）：锁定态 → pluginCandidates 子候选 → instant 统一列表 → AI 兜底。

        // 1. C-EXEC-ON-ENTER：参数态（lockedCommand != nil）+ Enter → submitCommandDirect 执行。
        if let locked = manager.lockedCommand {
            let q = query
            await MainActor.run {
                outputBuffer = ""
                actions = []
                errorOutput = nil
                resultImage = nil
                resultImageData = nil
                copied = false
            }
            callbackQuery = q
            callbackManifest = locked
            // C-ENTER-EXEC：锁定态 Enter 按 mode 分发（Tab 锁定已扩展到全插件，stdin/prompt 锁定态
            // 走 submitWithPlugin，command 仍走零 LLM submitCommandDirect——统一经 executePluginCandidate）
            let stream = manager.executePluginCandidate(locked, query: q)
            await consume(stream)
            return
        }

        // 2. C5 候选回调重入：post-exec 子候选态（pluginCandidates 非空）选中项 Enter →
        // 用 submitWithCandidate 重入同插件（带 selection），bypass LLM 执行选中动作（如 stop/start）。
        // 用首 Enter 保存的 callbackManifest，而非 lastRouteCandidates 按 lastRoutePluginName 查找——
        // 后者在 .done 清 query → updateQuery("") → lastRoutePluginName=nil 后查找失败 → 回调落 AI 流 → 执行失败。
        if !pluginCandidates.isEmpty,
           pluginCandidateIndex >= 0, pluginCandidateIndex < pluginCandidates.count,
           let manifest = callbackManifest {
            let sel = pluginCandidates[pluginCandidateIndex].selection
            let q = callbackQuery
            // 回调前清空候选列表 + 产物，进入新的结果展示
            await MainActor.run {
                pluginCandidates = []
                pluginCandidateIndex = -1
                outputBuffer = ""
                actions = []
                errorOutput = nil
                resultImage = nil
                resultImageData = nil
                copied = false
            }
            let stream = manager.submitWithCandidate(manifest, selection: sel, query: q)
            await consume(stream)
            return
        }

        // 3. D4 C-ENTER-EXEC：instant 统一列表选中行分流。
        //    插件行按 mode 分发（command → submitCommandDirect 零 LLM；stdin/prompt → submitWithPlugin）；
        //    app/内置行 → performSelectedInstantAction（C5 既有契约）。
        switch manager.submitInstantSelection(query: query) {
        case .performed:
            await MainActor.run { query = "" }
            return
        case .stream(let stream, let manifest):
            let q = query
            await MainActor.run {
                outputBuffer = ""
                actions = []
                errorOutput = nil
                resultImage = nil
                resultImageData = nil
                copied = false
            }
            // 记录原始 query + manifest（候选回调 C5 用：同 query 重入同插件）
            callbackQuery = q
            callbackManifest = manifest
            await consume(stream)
            return
        case .notInstant:
            break
        }

        // 4. fallback AI 兜底（无 UI 选中 → LLM 路由；现状不变）
        await MainActor.run {
            manager.clearInstantActions()
            outputBuffer = ""
            actions = []
            errorOutput = nil
            resultImage = nil
            copied = false
        }

        let selectedIdx = manager.lastRouteSelectedIndex
        let candidates = manager.lastRouteCandidates
        let q = query

        // 若用户通过键盘选了特定候选（selectedIndex >= 0），构造一个只含该候选的路由流
        let stream: AsyncStream<AgentEvent>
        if selectedIdx >= 0, selectedIdx < candidates.count {
            // 用已选中候选覆盖 AI 路由，直接进入 calling 阶段
            stream = manager.submitWithPlugin(candidates[selectedIdx], query: q)
        } else {
            stream = manager.submit(q)
        }
        // 记录原始 query + manifest（候选回调 C5 用：同 query 重入同插件）
        await MainActor.run {
            callbackQuery = q
            callbackManifest = candidates.isEmpty ? nil : candidates[selectedIdx >= 0 ? selectedIdx : 0]
        }
        await consume(stream)
    }

    /// 消费 AgentEvent 流并更新 UI state（submit / submitWithCandidate 共用）。
    private func consume(_ stream: AsyncStream<AgentEvent>) async {
        for await event in stream {
            switch event {
            case .text(let s):
                await MainActor.run {
                    outputBuffer += s   // 正文直接累积，渲染时整体 markdown 解析
                }
            case .toolCall(let name, _):
                await MainActor.run {
                    outputBuffer += "\n> 🔧 调用工具 `\(name)`...\n"
                }
            case .toolResult(let name, let output, let isError):
                await MainActor.run {
                    outputBuffer += isError
                        ? "\n> ❌ \(name): \(output)\n"
                        : "\n> ✅ \(name) →\n```\n\(output)\n```\n"
                }
            case .action(let button):
                await MainActor.run {
                    actions.append(button)   // render-only：收进底部工具条，不执行
                }
            case .image(let data):
                await MainActor.run {
                    resultImageData = data               // 保留原始 PNG 字节（场景3.P2 点击复制字节一致）
                    resultImage = NSImage(data: data)   // 图片通道：PNG → NSImage（渲染用）
                    copied = false
                }
            case .candidates(let items):
                await MainActor.run {
                    pluginCandidates = items            // 候选输出通道：收集候选列表（C1）
                    pluginCandidateIndex = items.isEmpty ? -1 : 0  // 默认选中首个（↑↓ + Enter）
                }
            case .done:
                await MainActor.run {
                    query = ""
                    // C-EXEC-ON-ENTER 收尾：执行完成清 lockedCommand，回到初始候选态
                    manager.resetLockedCommandAfterDone()
                    focused = true   // 流式结束后重新聚焦输入框，方便连续提问
                }
            case .error(let err):
                await MainActor.run {
                    errorOutput = MarkdownRenderer.renderError(err)
                    focused = true   // 出错后也重新聚焦，方便重试
                }
            }
        }
    }
}

// MARK: - panelHeight 纯函数（C3 / C7 契约）

extension LauncherInputView {
    /// 自适应面板高度公式（D6 统一混排简化版）。
    /// output 态 / 统一候选列表态（instant 单区 + pluginCandidateExtra 叠加）/ 空态。
    static func panelHeight(
        candidateCount: Int,
        hasSelected: Bool,
        outputHeight: CGFloat,
        hasFooter: Bool = false,
        instantCount: Int = 0,
        pluginCandidateCount: Int = 0
    ) -> CGFloat {
        let footerExtra: CGFloat = hasFooter ? LauncherConstants.statusFooterHeight : 0
        let inputH = LauncherConstants.inputHeight   // 64
        // 插件候选列表（C1 通道）单独计高：与 output 互斥展示（候选选中后进入 output 态）
        // C-VIEWPORT-THRESHOLD / C-ROW-HEIGHT-CONST：cap candidateVisibleMax(8)，行高用 candidateRowHeight
        let pluginCandidateExtra: CGFloat = CGFloat(min(pluginCandidateCount, LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight
        // output 态：instant 被 hasOutput guard 隐藏不计
        if outputHeight > 0 {
            return inputH + (hasSelected ? LauncherConstants.candidateRowHeight : 0) + min(outputHeight, LauncherConstants.outputMaxHeight) + pluginCandidateExtra + footerExtra
        }
        // 统一候选列表态：instant 单区（含插件/app/内置混排）
        let instantExtra: CGFloat = CGFloat(min(max(instantCount, 0), LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight
        if instantExtra > 0 {
            return inputH + instantExtra + pluginCandidateExtra + footerExtra
        }
        // 仅 pluginCandidates 通道态。
        // I3：lastRouteCandidates(candidateCount) 不渲染为可见列表，不从 panelHeight 分配高度
        // （否则 >8 时空白行）。仅 pluginCandidateCount 计高并 cap candidateVisibleMax。
        let effectiveCount = max(pluginCandidateCount, 0)
        if effectiveCount > 0 {
            return inputH + CGFloat(min(effectiveCount, LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight + footerExtra
        }
        // 空态
        return inputH + footerExtra
    }
}
