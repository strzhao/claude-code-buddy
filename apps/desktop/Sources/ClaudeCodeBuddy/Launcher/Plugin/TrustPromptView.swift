import SwiftUI

// MARK: - TrustPromptView（方案 B：自定义窗口全内容 SwiftUI）
//
// 用户真机反馈「布局遮挡 + 整体变大 + 背景毛玻璃」，从 NSAlert accessoryView 升级为
// 自定义 NSWindow 全内容 SwiftUI（TrustPromptWindow 毛玻璃壳 + 本视图全 4 区）。
//
// 四层结构（Cross.Freshness2 三层 + 按钮区，一个窗口内完成信任+依赖+进度+按钮）：
// 1. 信任说明区：插件名 + mode-aware informativeText（stdin/command/prompt 命令/路径/模型摘要）+ 信任标记（首次/已授权）
// 2. 依赖列表区：每个依赖行（状态 badge + Homebrew 来源标签 + 一键安装全部按钮）
// 3. 进度区：installingLabel + progressPhase + ProgressView + 取消（@ObservedObject installer @Published 驱动）
// 4. 按钮区：「允许并运行」（依赖全装才 enable，Q1）+「拒绝」
//
// pump 论证（M4 弹框内 runModal pump，plan-reviewer 第 3 轮 BLOCKER 5 已论证）：
// - NSApp.runModal(for:) 走 NSDefaultModalRunMode（common modes 子集）
// - GCD main queue（Task @MainActor）+ SwiftUI @Published → NSHostingView invalidation 均走 common modes
// - 故 runModal 期间全内容 SwiftUI @Published 刷新正常 pump
struct TrustPromptView: View {

    /// 插件信息（信任说明区展示 plugin 名）。
    let pluginName: String
    /// mode-aware 信任说明文本（stdin/command 命令+路径，prompt 模型+systemPrompt 摘要）。
    let informativeText: String
    /// 依赖状态列表（缺失项，供展示）。
    let statuses: [DependencyStatus]
    /// brew 可用性（缺失时显示引导文本）。
    let brewAvailability: BrewAvailability
    /// 是否已信任（重弹时标记「已授权」，不重复授权动作）。
    let isAlreadyTrusted: Bool
    /// 是否有依赖（true 时展示依赖区 + 按钮文案调整；无依赖纯信任框不展示依赖区）。
    let hasDeps: Bool
    /// 全局开关是否启用（关时显示命令 + 复制，非自动装）。
    let autoInstallEnabled: Bool

    /// M4 弹框内修订：@ObservedObject installer（绑定 @Published，全内容实时刷新）。
    @ObservedObject var installer: DependencyInstaller

    /// 一键安装按钮 action（TrustPrompt.askUserWithDeps 注入：Task @MainActor { installer.installAll(missing) }）。
    let onInstallAll: () -> Void
    /// 取消安装按钮 action（TrustPrompt.askUserWithDeps 注入：installer.cancel()）。
    let onCancel: () -> Void
    /// 「允许并运行」按钮 action（TrustPrompt.askUserWithDeps 注入：NSApp.stopModal(withCode:.OK)）。
    let onApprove: () -> Void
    /// 「拒绝」按钮 action（TrustPrompt.askUserWithDeps 注入：NSApp.stopModal(withCode:.cancel)）。
    let onDeny: () -> Void

    init(
        pluginName: String,
        informativeText: String,
        statuses: [DependencyStatus],
        brewAvailability: BrewAvailability = .available(path: ""),
        isAlreadyTrusted: Bool = false,
        hasDeps: Bool = true,
        autoInstallEnabled: Bool = true,
        installer: DependencyInstaller,
        onInstallAll: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onApprove: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {}
    ) {
        self.pluginName = pluginName
        self.informativeText = informativeText
        self.statuses = statuses
        self.brewAvailability = brewAvailability
        self.isAlreadyTrusted = isAlreadyTrusted
        self.hasDeps = hasDeps
        self.autoInstallEnabled = autoInstallEnabled
        self.installer = installer
        self.onInstallAll = onInstallAll
        self.onCancel = onCancel
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    /// 「允许并运行」按钮是否可用（依赖全装才 enable，Q1 修复保留）。
    /// 无依赖场景（hasDeps=false）恒 enable（纯信任框）。
    private var approveEnabled: Bool {
        guard hasDeps else { return true }
        // 用 installer 实时 statuses 判定（installAll 完成后会重新 locateBinary 更新 isInstalled）
        let effective = installer.statuses.isEmpty ? statuses : installer.statuses
        return effective.allSatisfy { $0.isInstalled }
    }

    /// 主按钮文案（场景 3：已信任重弹无 TOFU 信任动作，仅安装）。
    private var approveButtonTitle: String {
        if isAlreadyTrusted && hasDeps {
            return "安装并运行"
        } else if hasDeps {
            return "允许并运行"
        } else {
            return "允许"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: 1. 信任说明区（plugin 名 + mode-aware informativeText + 信任标记）
            trustSection

            Divider().opacity(0.5)

            // MARK: 2. 依赖列表区（hasDeps=true 才展示）
            if hasDeps && !statuses.isEmpty {
                dependencySection
            }

            // MARK: 3. 进度区（@Published 驱动，installingLabel 非 nil = 有活跃安装）
            if installer.installingLabel != nil {
                progressSection
            }

            Spacer(minLength: 4)

            // MARK: 4. 按钮区（「允许并运行」+「拒绝」）
            buttonSection
        }
        .padding(24)
        .background(VisualEffectBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("trust-prompt-content")
    }

    // MARK: - 信任说明区

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isAlreadyTrusted ? "checkmark.seal.fill" : "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(isAlreadyTrusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pluginName)
                        .font(.headline)
                        .accessibilityIdentifier("trust-prompt-plugin-name")
                    if isAlreadyTrusted {
                        Text("已授权，仅需安装依赖")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("trust-prompt-already-trusted")
                    } else {
                        Text("首次执行，需要授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(informativeText)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("trust-prompt-informative-text")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trust-prompt-trust-region")
    }

    // MARK: - 依赖列表区（Cross.Freshness1：独立 AXGroup + 来源标签）

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("依赖")
                    .font(.headline)
            }
            .accessibilityAddTraits(.isHeader)

            // brew 缺失引导
            if case .missing = brewAvailability {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("需要 Homebrew 才能自动安装以下依赖。请打开 brew.sh 安装 Homebrew 后重试。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("trust-prompt-brew-missing-hint")
            } else if !autoInstallEnabled {
                // 全局开关关：显示命令 + 复制提示
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("自动安装已关闭。请手动执行下列命令安装依赖：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("trust-prompt-manual-hint")
            }
            // 注：原「一键安装全部依赖」按钮已合并到「允许并运行」（点击允许 → installAllSync 自动装缺失依赖 + 装完执行，简化用户操作）

            // 每个依赖一行
            ForEach(statuses, id: \.check) { status in
                DependencyRow(
                    status: status,
                    brewAvailable: brewAvailableBool,
                    autoInstallEnabled: autoInstallEnabled,
                    installerStatuses: installer.statuses
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trust-prompt-dependency-list")
    }

    // MARK: - 进度区（@Published 驱动）

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    if let label = installer.installingLabel {
                        Text("正在安装：\(label)")
                            .font(.callout)
                    }
                    if !installer.progressPhase.isEmpty {
                        Text(installer.progressPhase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onCancel) {
                    Label("取消", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("trust-prompt-progress-cancel-button")
            }
            .accessibilityIdentifier("trust-prompt-installing-progress")
        }
    }

    // MARK: - 按钮区（「允许并运行」+「拒绝」）

    private var buttonSection: some View {
        HStack {
            Spacer()
            Button(action: onDeny) {
                Text("拒绝")
                    .frame(width: 96)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("trust-prompt-deny-button")

            Button(action: onApprove) {
                Text(approveButtonTitle)
                    .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("trust-prompt-approve-button")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trust-prompt-button-region")
    }

    private var brewAvailableBool: Bool {
        if case .available = brewAvailability { return true }
        return false
    }
}

// MARK: - DependencyRow（单个依赖卡片，M4 弹框内：状态 badge 含安装中/失败）

/// 单个依赖的展示行：check + label + 状态 badge + 来源标签。
///
/// M4 弹框内修订：状态 badge 从 installer.statuses（@Published）实时读 isInstalled，
/// 覆盖安装中（⟳）/ 失败（✗）/ 成功（✓）状态迁移（场景 1.P2b OST）。
struct DependencyRow: View {
    let status: DependencyStatus
    let brewAvailable: Bool
    let autoInstallEnabled: Bool
    /// installer 实时状态（@Published 快照，覆盖传入 status 的 isInstalled）。
    /// 默认空数组（无 installer 绑定时用传入 status 的 isInstalled）。
    var installerStatuses: [DependencyStatus] = []

    /// 从 installer.statuses 查实时状态（若同名则取 installer 版本，否则用传入 status）。
    private var effectiveStatus: DependencyStatus {
        installerStatuses.first { $0.check == status.check } ?? status
    }

    var body: some View {
        HStack(spacing: 10) {
            // 状态 badge
            statusBadge

            // 命令名 + 人话描述
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(effectiveStatus.check)
                        .font(.system(.body, design: .monospaced))
                    if let label = effectiveStatus.label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 全局开关关 → 显示命令
                if !autoInstallEnabled, let brew = effectiveStatus.brewPackage {
                    Text("brew install \(brew)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("trust-prompt-dep-command-\(effectiveStatus.check)")
                }
            }

            Spacer()

            // 来源标签（Homebrew）
            if effectiveStatus.brewPackage != nil, brewAvailable, autoInstallEnabled {
                Text("Homebrew")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("trust-prompt-dep-source-\(effectiveStatus.check)")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trust-prompt-dep-\(effectiveStatus.check)")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !brewAvailable {
            // brew 缺失
            Label("需 Homebrew", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !autoInstallEnabled {
            // 手动安装
            Label("手动", systemImage: "doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.blue)
        } else if effectiveStatus.isInstalled {
            // 已装（✓ 绿）
            Label("已装", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            // 未装（⚡ 橙，待一键安装）
            Label("未装", systemImage: "bolt")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - 复制命令辅助（供全局开关关时复制）

extension TrustPromptView {
    /// 全局开关关时，生成全部缺失依赖的 brew install 命令（换行分隔），供复制。
    static func brewInstallCommands(for statuses: [DependencyStatus]) -> String {
        statuses
            .compactMap { $0.brewPackage.map { "brew install \($0)" } }
            .joined(separator: "\n")
    }
}
