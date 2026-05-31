import SwiftUI

struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    @State private var query: String = ""
    @State private var outputBuffer: String = ""            // 流式累积 markdown 原文
    @State private var segments: [ActionSegment]?           // 预处理后的 segment 列表
    @State private var errorOutput: AttributedString?       // 仅用于 .error 路径
    @State private var visible: Bool = false                // 入场动画状态（C6 契约）
    @FocusState private var focused: Bool

    /// 派生自 manager.stage（不再维护独立 @State isRunning）
    private var isRunning: Bool {
        manager.stage != .idle && manager.stage != .error
    }

    /// 是否有可见输出（segments 非空 or 有错误输出）
    private var hasOutput: Bool {
        !(segments?.isEmpty ?? true) || errorOutput != nil
    }

    /// 命中的 plugin 名字（chip 水印显示用）
    /// 直接跟随 manager.lastRoutePluginName（updateQuery 同步算 narrow 维护，
    /// 用户清空输入 → updateQuery 把它设 nil → chip 自动消失）
    private var activePluginName: String? {
        manager.lastRoutePluginName
    }

    /// 内置 App 候选（AppLauncher 用）是否显示：safe period 且无结果展示
    /// 外部 plugin 候选行已完全去掉（用 chip 水印替代）
    private var showInstantCandidates: Bool {
        guard !hasOutput else { return false }
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

                    // Plugin watermark chip — 显示命中的 plugin 名称
                    if let pluginName = activePluginName {
                        PluginWatermarkChip(name: pluginName)
                            .padding(.trailing, 14)
                    }
                }

                // 执行中 3 点脉冲动画（C8 契约）
                LauncherPulseDots()
                    .padding(.trailing, LauncherConstants.inputPaddingH)
                    .opacity(isRunning ? 1 : 0)
            }
            .frame(height: LauncherConstants.inputHeight)

            // 内置 App 候选（AppLauncher）保留；外部 plugin 候选行已删（用 chip 水印替代）
            if showInstantCandidates && !manager.instantActions.isEmpty {
                LauncherInstantCandidateView(
                    actions: manager.instantActions,
                    selectedIndex: manager.instantSelectedIndex
                )
            }

            // 底部状态栏（C5 契约）：stage != .idle 时显示
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
                // 1px hairline 分隔线（系统 separatorColor）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

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
                    } else if let segs = segments {
                        // 正常路径：ActionSegment 流式渲染
                        segmentedOutputView(segs)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: LauncherConstants.outputMaxHeight, alignment: .topLeading)
                .background(LauncherTheme.surface)
            }
        } // end VStack
        .frame(
            width: LauncherConstants.windowWidth,
            height: LauncherInputView.panelHeight(
                // 外部 plugin 候选行已删除，永远不占高度
                candidateCount: 0,
                hasSelected: false,
                outputHeight: hasOutput ? LauncherConstants.outputMaxHeight : 0,
                hasFooter: manager.stage == .error,
                instantCount: showInstantCandidates ? manager.instantActions.count : 0
            ),
            alignment: .top
        )
        // 视觉容器：SwiftUI .ultraThinMaterial 原生毛玻璃 (macOS 12+) + innerHighlight 内边框
        // 注：之前用 NSVisualEffectView 作为 NSHostingView subview 被 SwiftUI 渲染覆盖不可见，
        // 改用 SwiftUI 原生 Material（底层亦是 NSVisualEffectView）保证在渲染层级正确合成。
        // NSVisualEffectView 注入仍保留在 LauncherWindow 中作为 C1 红队契约的结构性兜底。
        .background(
            RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                        .strokeBorder(LauncherTheme.innerHighlight, lineWidth: 1)
                )
        )
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
            segments = nil
            errorOutput = nil
        }
        // 二次召唤（panel orderOut 后再 makeKeyAndOrderFront）时 view 实例复用，
        // onAppear 不重触发；监听 isVisible false→true 清空上次的 query/output/segments
        .onChange(of: manager.isVisible) { _, isNowVisible in
            if isNowVisible {
                query = ""
                outputBuffer = ""
                segments = nil
                errorOutput = nil
                focused = true
            }
        }
        .onDisappear {}
        .onExitCommand { manager.hide() }   // Esc → hide（focus 在 view 内时生效）
        // 上下箭头键导航候选列表：instant 优先，否则原有 lastRoute 逻辑（C5 契约）
        // task 011：instantActions 非空时，导航 instantSelectedIndex；否则导航 lastRouteSelectedIndex
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

    /// 向上移动选中：instant 候选优先，否则 AI 路由候选（循环）
    private func navigateUp() -> KeyPress.Result {
        if !manager.instantActions.isEmpty {
            manager.moveInstantSelection(up: true)
            return .handled
        }
        let count = manager.lastRouteCandidates.count
        guard count > 0 else { return .ignored }
        let current = manager.lastRouteSelectedIndex
        manager.setSelectedIndex((current <= 0) ? count - 1 : current - 1)
        return .handled
    }

    /// 向下移动选中：instant 候选优先，否则 AI 路由候选（循环）
    private func navigateDown() -> KeyPress.Result {
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

    private func submit() async {
        // task 011 C5 契约：内置管线优先 — 有选中的 instant action → 执行并结束，不触发 AI
        if manager.performSelectedInstantAction() {
            await MainActor.run { query = "" }
            return
        }

        // 落回现有 AI 流（清空 instantActions，进入 AI 候选时序）
        await MainActor.run {
            manager.clearInstantActions()
            outputBuffer = ""
            segments = nil
            errorOutput = nil
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

        for await event in stream {
            switch event {
            case .text(let s):
                await MainActor.run {
                    outputBuffer += s
                    segments = MarkdownActionParser.preprocess(outputBuffer)
                }
            case .toolCall(let name, _):
                await MainActor.run {
                    outputBuffer += "\n> 🔧 调用工具 `\(name)`...\n"
                    segments = MarkdownActionParser.preprocess(outputBuffer)
                }
            case .toolResult(let name, let output, let isError):
                await MainActor.run {
                    outputBuffer += isError
                        ? "\n> ❌ \(name): \(output)\n"
                        : "\n> ✅ \(name) →\n```\n\(output)\n```\n"
                    segments = MarkdownActionParser.preprocess(outputBuffer)
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

    // MARK: - Segment-based output rendering

    @ViewBuilder
    private func segmentedOutputView(_ segs: [ActionSegment]) -> some View {
        // 用 FlowLayout-like 思路：连续 .text 合并为 single Text + AttributedString，
        // .action 以 ActionButton 内联插入。
        // 实现策略：把所有 .text 段收集成一个大 markdown 再渲染，
        // ActionButton 出现在文本"断点"处，用 VStack 行排列（简单实用）。
        ActionSegmentsView(segments: segs)
            .padding(.horizontal, LauncherConstants.inputPaddingH)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - panelHeight 纯函数（C3 / C7 契约）

extension LauncherInputView {
    /// 三态自适应面板高度公式（C3/C7 契约）
    /// - Parameters:
    ///   - candidateCount: AI 路由候选数量
    ///   - hasSelected: 是否有选中候选（输出态时决定是否额外加 44）
    ///   - outputHeight: 输出内容高度（0 表示无输出）
    ///   - hasFooter: 是否有状态栏（额外加 22）
    ///   - instantCount: task 011 即时内置候选数量（两者时序互斥，取非零者）
    /// - Returns: 面板内容区高度
    static func panelHeight(
        candidateCount: Int,
        hasSelected: Bool,
        outputHeight: CGFloat,
        hasFooter: Bool = false,
        instantCount: Int = 0
    ) -> CGFloat {
        let footerExtra: CGFloat = hasFooter ? LauncherConstants.statusFooterHeight : 0
        let inputH = LauncherConstants.inputHeight   // 64
        if outputHeight > 0 {
            return inputH + (hasSelected ? 44 : 0) + min(outputHeight, 400) + footerExtra
        }
        // 时序互斥：instantCount 非零时用 instantCount，否则用 candidateCount
        let effectiveCount = max(instantCount, candidateCount)
        if effectiveCount > 0 {
            return inputH + CGFloat(min(effectiveCount, 5)) * 44 + footerExtra
        }
        return inputH + footerExtra
    }
}
