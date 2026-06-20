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

    /// 命中的 plugin 名字（chip 水印显示用）
    /// 直接跟随 manager.lastRoutePluginName（updateQuery 同步算 narrow 维护，
    /// 用户清空输入 → updateQuery 把它设 nil → chip 自动消失）
    private var activePluginName: String? {
        manager.lastRoutePluginName
    }

    /// 内置 App 候选（AppLauncher 用）是否显示：safe period 且无结果展示
    /// 方案 B：外部 command 插件候选行恢复（分区渲染，C3）
    private var showInstantCandidates: Bool {
        guard !hasOutput else { return false }
        return manager.stage == .idle || manager.stage == .narrowing || manager.stage == .routing
    }

    /// command 路由候选区是否显示（方案 B，C3）：safe period 且无结果展示且 commandRouteCandidates 非空。
    /// 与 showInstantCandidates 可同时为 true（两区并存渲染）。
    private var showCommandRouteCandidates: Bool {
        guard !hasOutput else { return false }
        return (manager.stage == .idle || manager.stage == .narrowing || manager.stage == .routing)
            && !manager.commandRouteCandidates.isEmpty
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

                    // Plugin watermark chip — 显示命中的 plugin 名称
                    if let pluginName = activePluginName {
                        PluginWatermarkChip(name: pluginName)
                            .padding(.trailing, 14)
                    }
                }
            }
            .frame(height: LauncherConstants.inputHeight)

            // command 路由候选区（方案 B C3/C7，最上层）：用户安装的 command 插件候选行。
            // 点击行 → onSelect 触发 submitCommandDirect（C11 command 短路执行）。
            if showCommandRouteCandidates {
                LauncherCandidateView(
                    candidates: manager.commandRouteCandidates,
                    // 单选高亮：只有 activeCandidateZone == .commandRoute 时本区才高亮，
                    // 非活动区传 -1（不亮）——保证任意时刻全屏只有一个高亮行（修真机两区同亮 bug）
                    selectedIndex: manager.activeCandidateZone == .commandRoute ? manager.commandRouteSelectedIndex : -1,
                    onSelect: { manifest in
                        // 点击定位索引后触发 submit（submit 按 activeCandidateZone 派发）
                        if let idx = manager.commandRouteCandidates.firstIndex(where: { $0.name == manifest.name }) {
                            manager.setCommandRouteSelectedIndex(idx)
                            manager.setActiveCandidateZone(.commandRoute)
                            Task { await submit() }
                        }
                    }
                )
            }

            // 内置 instant 候选区（AppLauncher/Calculator/SystemCommand 等，C3 之下）
            if showInstantCandidates && !manager.instantActions.isEmpty {
                LauncherInstantCandidateView(
                    actions: manager.instantActions,
                    // 单选高亮：只有 activeCandidateZone == .instant 时本区才高亮（非活动区传 -1）
                    selectedIndex: manager.activeCandidateZone == .instant ? manager.instantSelectedIndex : -1
                )
            }

            // 插件候选输出通道（C1）：command/stdin 插件返回的候选列表（如 qzh 的 stop/start）。
            // 用户 ↑↓ 选中 + Enter / 点击 → submitWithCandidate 回调（C5，执行权留插件）。
            if !pluginCandidates.isEmpty {
                LauncherPluginCandidateView(
                    candidates: pluginCandidates,
                    selectedIndex: pluginCandidateIndex,
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
                pluginCandidateCount: pluginCandidates.count,
                commandRouteCount: showCommandRouteCandidates ? manager.commandRouteCandidates.count : 0
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
        .onExitCommand { manager.hide() }   // Esc → hide（focus 在 view 内时生效）
        // 上下箭头键导航候选列表：instant 优先，否则原有 lastRoute 逻辑（C5 契约）
        .onKeyPress(.upArrow) { navigateUp() }
        .onKeyPress(.downArrow) { navigateDown() }
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
    }

    // MARK: - 候选导航（箭头 / emacs Ctrl-N·P 共用）

    /// 向上移动选中：C5 四态矩阵派发。
    /// pluginCandidates 通道(post-exec) 隔离 → commandRoute → instant → aiRoute 兜底。
    /// commandRoute+instant 并存：边界跨区（instant 首↑→commandRoute 末），区内环形。
    private func navigateUp() -> KeyPress.Result {
        // C5：pluginCandidates 通道非空 → 仅区内环形，隔离其他三区（既有短路保留）
        if !pluginCandidates.isEmpty {
            let count = pluginCandidates.count
            pluginCandidateIndex = (pluginCandidateIndex <= 0) ? count - 1 : pluginCandidateIndex - 1
            return .handled
        }
        // C5：activeCandidateZone 派发（commandRoute + instant 并存跨区）
        switch manager.activeCandidateZone {
        case .commandRoute:
            // commandRoute 首↑ → 跨区到 instant 末（instant 非空）或区内循环
            if manager.commandRouteSelectedIndex <= 0 && !manager.instantActions.isEmpty {
                manager.setActiveCandidateZone(.instant)
                // instant 末项（symmetric moveInstantSelection 在首项↑会循环到末项）
                manager.moveInstantSelection(up: true)
                return .handled
            }
            manager.moveCommandRouteSelection(up: true)
            return .handled
        case .instant:
            // instant 首↑ → 跨区到 commandRoute 末（commandRoute 非空）
            if manager.instantSelectedIndex <= 0 && !manager.commandRouteCandidates.isEmpty {
                manager.setActiveCandidateZone(.commandRoute)
                manager.setCommandRouteSelectedIndex(manager.commandRouteCandidates.count - 1)
                return .handled
            }
            manager.moveInstantSelection(up: true)
            return .handled
        case .pluginCandidates, .aiRoute:
            break
        }
        // aiRoute 兜底（lastRouteCandidates）
        let count = manager.lastRouteCandidates.count
        guard count > 0 else { return .ignored }
        let current = manager.lastRouteSelectedIndex
        manager.setSelectedIndex((current <= 0) ? count - 1 : current - 1)
        return .handled
    }

    /// 向下移动选中：C5 四态矩阵派发（对称 navigateUp）。
    private func navigateDown() -> KeyPress.Result {
        if !pluginCandidates.isEmpty {
            let count = pluginCandidates.count
            pluginCandidateIndex = (pluginCandidateIndex >= count - 1) ? 0 : pluginCandidateIndex + 1
            return .handled
        }
        switch manager.activeCandidateZone {
        case .commandRoute:
            // commandRoute 末↓ → 跨区到 instant 首（instant 非空）
            let cmdCount = manager.commandRouteCandidates.count
            if cmdCount > 0 && manager.commandRouteSelectedIndex >= cmdCount - 1 && !manager.instantActions.isEmpty {
                manager.setActiveCandidateZone(.instant)
                // instant 首项（moveInstantSelection 在末项↓会循环回首项；这里我们直接确保落首项）
                if manager.instantSelectedIndex < 0 {
                    manager.moveInstantSelection(up: false)
                }
                return .handled
            }
            manager.moveCommandRouteSelection(up: false)
            return .handled
        case .instant:
            // instant 末↓ → 跨区到 commandRoute 首（commandRoute 非空）
            let instCount = manager.instantActions.count
            if instCount > 0 && manager.instantSelectedIndex >= instCount - 1 && !manager.commandRouteCandidates.isEmpty {
                manager.setActiveCandidateZone(.commandRoute)
                manager.setCommandRouteSelectedIndex(0)
                return .handled
            }
            manager.moveInstantSelection(up: false)
            return .handled
        case .pluginCandidates, .aiRoute:
            break
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
        // 方案 B C4：Enter 优先级按 activeCandidateZone 派发。
        // commandRoute 优先（用户主动安装的 command 插件）→ instant → pluginCandidates 回调 → AI 路由。

        // C4：commandRoute 区选中 → submitCommandDirect（C11 command 短路，零 provider/零 LLM）→ return。
        if manager.activeCandidateZone == .commandRoute,
           manager.commandRouteCandidates.indices.contains(manager.commandRouteSelectedIndex) {
            let manifest = manager.commandRouteCandidates[manager.commandRouteSelectedIndex]
            let q = query
            // 回调前清空产物，进入新的结果展示
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
            let stream = manager.submitCommandDirect(manifest, query: q)
            await consume(stream)
            return
        }

        // C4：instant 区 → performSelectedInstantAction（既有 task 011 C5 契约）
        if manager.activeCandidateZone == .instant, manager.performSelectedInstantAction() {
            await MainActor.run { query = "" }
            return
        }

        // C5 候选回调重入：若上一轮 command 插件返回了候选列表且用户选中某项 →
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

        // 落回现有 AI 流（清空 instantActions，进入 AI 候选时序）
        await MainActor.run {
            manager.clearInstantActions()
            outputBuffer = ""
            actions = []
            errorOutput = nil
            resultImage = nil
            copied = false
        }

        // Enter 优先：若 selectedIndex >= 0 且有候选，直接用该候选执行（C5 契约，原有外部 CLI 分支）
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
    /// 四态自适应面板高度公式（方案 B C6，取代既有 max 互斥）。
    /// output 态 / 候选并存态(commandRoute+instant 叠加) / 仅单区态(C10 回归) / 空态。
    static func panelHeight(
        candidateCount: Int,
        hasSelected: Bool,
        outputHeight: CGFloat,
        hasFooter: Bool = false,
        instantCount: Int = 0,
        pluginCandidateCount: Int = 0,
        commandRouteCount: Int = 0
    ) -> CGFloat {
        let footerExtra: CGFloat = hasFooter ? LauncherConstants.statusFooterHeight : 0
        let inputH = LauncherConstants.inputHeight   // 64
        // 插件候选列表（C1 通道）单独计高：与 output 互斥展示（候选选中后进入 output 态）
        let pluginCandidateExtra: CGFloat = CGFloat(min(pluginCandidateCount, 5)) * 44
        // C6 output 态：commandRoute/instant 被 hasOutput guard 隐藏不计
        if outputHeight > 0 {
            return inputH + (hasSelected ? 44 : 0) + min(outputHeight, 400) + pluginCandidateExtra + footerExtra
        }
        // C6 候选并存态：commandRoute + instant 叠加（非 max）
        let commandRouteExtra: CGFloat = CGFloat(min(commandRouteCount, 5)) * 44
        let instantExtra: CGFloat = CGFloat(min(instantCount, 5)) * 44
        let combinedExtra = commandRouteExtra + instantExtra
        if combinedExtra > 0 {
            return inputH + combinedExtra + pluginCandidateExtra + footerExtra
        }
        // C6 仅单区态（C10 回归）+ lastRouteCandidates（candidateCount）兜底
        let effectiveCount = max(max(pluginCandidateCount, candidateCount), 0)
        if effectiveCount > 0 {
            return inputH + CGFloat(min(effectiveCount, 5)) * 44 + footerExtra
        }
        // C6 空态
        return inputH + footerExtra
    }
}
