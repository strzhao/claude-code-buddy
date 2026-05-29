import SwiftUI

struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    @State private var query: String = ""
    @State private var outputBuffer: String = ""            // 流式累积 markdown 原文
    @State private var rendered: AttributedString?          // 渲染后 markdown
    @FocusState private var focused: Bool

    /// 派生自 manager.stage（不再维护独立 @State isRunning）
    private var isRunning: Bool {
        manager.stage != .idle && manager.stage != .error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 输入区
            HStack(spacing: 8) {
                TextField("Ask anything...", text: $query)
                    .textFieldStyle(.plain)
                    .font(LauncherTheme.bodyText)
                    .foregroundStyle(LauncherTheme.ink)
                    .padding(.horizontal, LauncherConstants.inputPaddingH)
                    .padding(.vertical, LauncherConstants.inputPaddingV)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focused)
                    .disabled(isRunning)
                    .onSubmit { Task { await submit() } }
                    .onChange(of: query) { _, new in
                        if new.count > LauncherConstants.maxQueryLength {
                            query = String(new.prefix(LauncherConstants.maxQueryLength))
                        }
                    }

                // 执行中 3 点脉冲动画（C8 契约）
                LauncherPulseDots()
                    .padding(.trailing, LauncherConstants.inputPaddingH)
                    .opacity(isRunning ? 1 : 0)
            }

            // 候选插件列表（仅在 candidates 非空时显示）
            LauncherCandidateView(
                candidates: manager.lastRouteCandidates,
                selectedIndex: manager.lastRouteSelectedIndex
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
            if let out = rendered {
                // 1px hairline 分隔线
                LauncherTheme.borderPixel.opacity(0.4)
                    .frame(height: 1)

                ScrollView {
                    Text(out)
                        .font(LauncherTheme.outputBody)
                        .foregroundStyle(LauncherTheme.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, LauncherConstants.inputPaddingH)
                        .padding(.vertical, 12)
                }
                .frame(maxHeight: LauncherConstants.outputMaxHeight)
                .background(LauncherTheme.surface)
            }
        } // end VStack
        .frame(
            width: LauncherConstants.windowWidth,
            height: LauncherInputView.panelHeight(
                candidateCount: manager.lastRouteCandidates.count,
                hasSelected: manager.lastRouteSelectedIndex >= 0,
                outputHeight: rendered != nil ? LauncherConstants.outputMaxHeight : 0
            ),
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                .fill(LauncherTheme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                        .strokeBorder(LauncherTheme.borderPixel,
                                      lineWidth: LauncherTheme.pixelBorderWidth)
                )
                .shadow(color: LauncherTheme.shadowPixel, radius: 0,
                        x: LauncherTheme.pixelShadowOffset.width,
                        y: LauncherTheme.pixelShadowOffset.height)
        )
        .onAppear {
            focused = true
            query = ""
            outputBuffer = ""
            rendered = nil
        }
        .onDisappear {}
        .onExitCommand { manager.hide() }   // Esc → hide
        // 上下箭头键导航候选列表（C5 契约）：循环跳转
        .onKeyPress(.upArrow) {
            let count = manager.lastRouteCandidates.count
            guard count > 0 else { return .ignored }
            let current = manager.lastRouteSelectedIndex
            // 循环：< 0 或 == 0 跳到末尾
            let next = (current <= 0) ? count - 1 : current - 1
            manager.setSelectedIndex(next)
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = manager.lastRouteCandidates.count
            guard count > 0 else { return .ignored }
            let current = manager.lastRouteSelectedIndex
            // 循环：到末尾跳回 0
            let next = (current >= count - 1) ? 0 : current + 1
            manager.setSelectedIndex(next)
            return .handled
        }
    }

    private func submit() async {
        // Enter 优先：若 selectedIndex >= 0 且有候选，直接用该候选执行（C5 契约）
        let selectedIdx = manager.lastRouteSelectedIndex
        let candidates = manager.lastRouteCandidates
        let q = query

        await MainActor.run {
            outputBuffer = ""
            rendered = nil
        }

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
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .toolCall(let name, _):
                await MainActor.run {
                    outputBuffer += "\n> 🔧 调用工具 `\(name)`...\n"
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .toolResult(let name, let output, let isError):
                await MainActor.run {
                    outputBuffer += isError
                        ? "\n> ❌ \(name): \(output)\n"
                        : "\n> ✅ \(name) →\n```\n\(output)\n```\n"
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .done:
                await MainActor.run { query = "" }
            case .error(let err):
                await MainActor.run {
                    rendered = MarkdownRenderer.renderError(err)
                }
            }
        }
    }
}

// MARK: - panelHeight 纯函数（C3 / C7 契约）

extension LauncherInputView {
    /// 三态自适应面板高度公式（C3/C7 契约）
    /// - Parameters:
    ///   - candidateCount: 候选数量
    ///   - hasSelected: 是否有选中候选（输出态时决定是否额外加 44）
    ///   - outputHeight: 输出内容高度（0 表示无输出）
    /// - Returns: 面板内容区高度
    static func panelHeight(candidateCount: Int, hasSelected: Bool, outputHeight: CGFloat) -> CGFloat {
        if outputHeight > 0 {
            return 90 + (hasSelected ? 44 : 0) + min(outputHeight, 400)
        }
        if candidateCount > 0 {
            return 90 + CGFloat(min(candidateCount, 5)) * 44
        }
        return 90
    }
}
