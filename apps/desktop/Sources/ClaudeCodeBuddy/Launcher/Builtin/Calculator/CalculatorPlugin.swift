import AppKit

/// 计算器内置插件（CALC 契约）。
///
/// launcher 输入数学表达式（`1+2*3`、`(5-3)/2`、`2^10`、`7%2`）时即时出 `= 结果` 候选，
/// 回车复制结果到剪贴板。零侵入 LauncherManager（仅注册到 BuiltinPluginRegistry）。
///
/// 设计要点：
/// 1. 纯 Swift 手写 `MathEvaluator`，不用 NSExpression / JavaScriptCore —— 安全 / 可测 / 语义可控。
/// 2. 激活门控：仅当 query 含运算符字符才求值；裸数字让 AppLauncher 接管。
/// 3. priority=200（高于 SystemCommand 的 100）；score=1000（激活即满分类 SystemCommand 完全匹配）。
///
/// @MainActor：live 管线全程主线程，规避 NSImage / 闭包跨 actor 的 Sendable 问题。
@MainActor
final class CalculatorPlugin: BuiltinPlugin {

    static let shared = CalculatorPlugin()

    // MARK: - BuiltinPlugin 契约（CALC1）

    let id = "calculator"
    let priority: Int = 200
    let sectionTitle = "计算"

    // C2：人话文案（设置页 / debug registry 展示）
    let summary = "计算器：输入算式即时算出结果，回车复制"
    let description = "在输入框直接敲数学算式（如 1+2*3、(5-3)/2、2^10、7%2），会立刻显示结果，按回车把结果复制到剪贴板。支持加减乘除、括号、百分号和乘方。"

    // MARK: - 执行 seam（可注入，用于测试）

    private let copyService: CopyService

    /// 测试注入用 init（不使用默认参数引用 @MainActor 属性，镜像 SystemCommandPlugin 风格）。
    init(copyService: CopyService = .shared) {
        self.copyService = copyService
    }

    // MARK: - actions(for:)（CALC2–CALC4）

    /// query 求值流程：
    /// - 空 query → `[]`
    /// - 不含运算符字符（裸数字 / 字母）→ `[]`（白名单拒非法字符在 evaluate 内部完成）
    /// - 求值失败（含非法字符 / 除零 / 溢出）→ `[]`
    /// - 求值成功 → 单个 `LauncherAction`，`score=1000` 置顶
    func actions(for query: String) async -> [LauncherAction] {
        let normalized = query.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        // CALC2 激活门控：不含运算符字符（裸数字）→ 让 AppLauncher 接管
        guard MathEvaluator.looksLikeComputation(normalized) else { return [] }

        // CALC3 求值
        let result: Result<Double, MathEvaluator.MathError>
        switch MathEvaluator.evaluate(normalized) {
        case .success(let value):
            result = .success(value)
        case .failure:
            // 求值失败（语法错误 / 除零 / 溢出）→ 不出候选
            return []
        }

        // CALC4 结果呈现
        guard case .success(let value) = result else { return [] }
        let formatted = MathEvaluator.format(value)
        // title 带 "= " 前缀供显示；perform 复制裸结果（便于粘贴到其他计算器/表格）
        let displayTitle = "= \(formatted)"

        // 闭包捕获 formatted 与 copyService（@MainActor 闭包，OK）
        let copyService = self.copyService
        let action = LauncherAction(
            id: "calculator.result",
            title: displayTitle,
            subtitle: "\(normalized) · 回车复制",
            icon: NSImage(systemSymbolName: "function", accessibilityDescription: "计算"),
            pluginId: self.id,
            score: 1000,
            perform: {
                copyService.copy(formatted)
            }
        )
        return [action]
    }
}
