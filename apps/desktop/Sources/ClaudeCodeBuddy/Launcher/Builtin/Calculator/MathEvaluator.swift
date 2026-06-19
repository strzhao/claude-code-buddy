import Foundation

/// 数学表达式求值器（CALC 契约）。
///
/// 纯 Swift 手写递归下降解析器，零 AppKit / NSExpression / JavaScriptCore 依赖。
/// 安全：char 白名单从结构上杜绝注入；语义可控；可测：纯函数无实例状态。
///
/// 文法（优先级低→高）：
/// ```
/// expr   := term (('+' | '-') term)*
/// term   := factor (('*' | '/' | '%') factor)*
/// factor := unary ('^' factor)?          // ^ 右结合
/// unary  := ('+' | '-') unary | primary
/// primary:= number | '(' expr ')'
/// number := digits ['.' digits]
/// ```
enum MathEvaluator {

    // MARK: - 公开 API（CALC1 契约）

    /// 求值错误（Equatable 供测试断言；Error 满足 Result.Failure 约束）。
    enum MathError: Error, Equatable {
        /// query trim 后为空
        case empty
        /// 非法字符 / 括号不匹配 / 不完整表达式
        case syntaxError
        /// x / 0 或 x % 0
        case divisionByZero
        /// 结果 isInfinite（如 1/0 已被 divisionByZero 拦截，此处兜底溢出路径）
        case overflow
    }

    /// 对表达式求值，返回结果或错误。
    static func evaluate(_ expr: String) -> Result<Double, MathError> {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .failure(.empty)
        }

        // char 白名单校验：仅允许数字、空白、点、运算符、括号
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/%^() ").union(.whitespaces)
        if !trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return .failure(.syntaxError)
        }

        // tokenize：数字串 + 单字符运算符
        let tokens: [Token]
        switch tokenize(trimmed) {
        case .success(let t):
            tokens = t
        case .failure(let e):
            return .failure(e)
        }

        // 解析求值
        var parser = Parser(tokens: tokens)
        let value: Double
        switch parser.parseExpr() {
        case .success(let v):
            value = v
        case .failure(let e):
            return .failure(e)
        }

        // 必须消费完所有 token（否则如 "1 2" 残留 → 不完整表达式）
        if !parser.isAtEnd {
            return .failure(.syntaxError)
        }

        if value.isNaN || value.isInfinite {
            return .failure(.overflow)
        }
        return .success(value)
    }

    /// 激活门控：query 是否「看起来像」一个数学运算。
    ///
    /// 规则：
    /// - 含 `* / % ^ (` → 必激活（这些字符在合法表达式里只能是二元运算符或括号）
    /// - 含 `+ -` → 激活；但「前导单符号 + 纯数字」（如 `-5` / `+5`）不算运算
    ///   （语义上是带符号的数字而非运算式，让 AppLauncher 接管）
    /// - 裸数字（如 `365`）→ false
    ///
    /// 实现等价：trim 后剥掉至多一个前导 `+`/`-`，再判断剩余是否含任意运算符字符。
    /// 这样 `-5` → 剥成 `5` → false；`-5+3` → 剥成 `5+3` → true；`5-3` → 不剥（首位非符号）→ true。
    static func looksLikeComputation(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        var body = trimmed
        // 剥掉至多一个前导符号（一元正负号），其余符号一律视为激活信号
        if let first = body.first, first == "+" || first == "-" {
            body.removeFirst()
        }

        let operatorChars = CharacterSet(charactersIn: "+-*/%^()")
        return body.unicodeScalars.contains { operatorChars.contains($0) }
    }

    /// 格式化结果：
    /// - 整数值（`value == value.rounded()` 且 `abs(value) < 1e15`）→ 去 `.0`
    /// - 否则四舍五入到 10 位有效小数再截尾零
    /// - `-0` / `0` → `"0"`
    static func format(_ value: Double) -> String {
        // -0 归一化
        let normalized = value == 0 ? 0.0 : value

        // 整数路径
        if normalized == normalized.rounded() && abs(normalized) < 1e15 {
            return String(Int64(normalized))
        }

        // 小数路径：限制 10 位有效小数
        // 用 %.(10)f 四舍五入到 10 位，再截尾零和孤立的小数点
        let rounded = String(format: "%.10f", normalized)
        var result = rounded
        if result.contains(".") {
            // 截尾零
            while result.hasSuffix("0") {
                result.removeLast()
            }
            // 若以小数点结尾则一并去掉（理论上此分支不会触发，因小数路径必有小数部分）
            if result.hasSuffix(".") {
                result.removeLast()
            }
        }
        return result
    }

    // MARK: - 内部实现

    /// 单字符 token（数字串合并为一个 token）。
    private enum Token: Equatable {
        case number(Double)
        case op(Character)
    }

    /// 词法分析：将字符流转为 token 流。
    private static func tokenize(_ s: String) -> Result<[Token], MathError> {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace {
                i += 1
                continue
            }

            if c.isNumber || c == "." {
                // 数字串：连续 [0-9.]（`.` 可多次出现，由 Double 解析报错兜底）
                var numStr = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    numStr.append(chars[i])
                    i += 1
                }
                guard let value = Double(numStr) else {
                    return .failure(.syntaxError)
                }
                tokens.append(.number(value))
                continue
            }

            if "+-*/%^()".contains(c) {
                tokens.append(.op(c))
                i += 1
                continue
            }

            // 白名单已保证此处不可达，防御性兜底
            return .failure(.syntaxError)
        }

        return .success(tokens)
    }

    /// 递归下降解析器。
    private struct Parser {
        let tokens: [Token]
        var pos = 0

        var current: Token? {
            pos < tokens.count ? tokens[pos] : nil
        }

        var isAtEnd: Bool {
            pos >= tokens.count
        }

        private mutating func advance() -> Token? {
            let t = current
            pos += 1
            return t
        }

        /// expr := term (('+' | '-') term)*
        mutating func parseExpr() -> Result<Double, MathError> {
            var result: Double
            switch parseTerm() {
            case .success(let v): result = v
            case .failure(let e): return .failure(e)
            }

            while case .op(let c) = current, c == "+" || c == "-" {
                _ = advance()
                switch parseTerm() {
                case .success(let rhs):
                    result = c == "+" ? result + rhs : result - rhs
                case .failure(let e):
                    return .failure(e)
                }
            }
            return .success(result)
        }

        /// term := factor (('*' | '/' | '%') factor)*
        mutating func parseTerm() -> Result<Double, MathError> {
            var result: Double
            switch parseFactor() {
            case .success(let v): result = v
            case .failure(let e): return .failure(e)
            }

            while case .op(let c) = current, c == "*" || c == "/" || c == "%" {
                _ = advance()
                switch parseFactor() {
                case .success(let rhs):
                    switch c {
                    case "*":
                        result *= rhs
                    case "/":
                        if rhs == 0 { return .failure(.divisionByZero) }
                        result /= rhs
                    case "%":
                        if rhs == 0 { return .failure(.divisionByZero) }
                        // Swift % 对 Double 也定义（遵循 truncated 除法余数）
                        result = result.truncatingRemainder(dividingBy: rhs)
                    default:
                        break
                    }
                case .failure(let e):
                    return .failure(e)
                }
            }
            return .success(result)
        }

        /// factor := unary ('^' factor)?  — ^ 右结合
        mutating func parseFactor() -> Result<Double, MathError> {
            var base: Double
            switch parseUnary() {
            case .success(let v): base = v
            case .failure(let e): return .failure(e)
            }

            if case .op("^") = current {
                _ = advance()
                switch parseFactor() {
                case .success(let exponent):
                    let result = pow(base, exponent)
                    if result.isNaN || result.isInfinite {
                        return .failure(.overflow)
                    }
                    base = result
                case .failure(let e):
                    return .failure(e)
                }
            }
            return .success(base)
        }

        /// unary := ('+' | '-') unary | primary
        mutating func parseUnary() -> Result<Double, MathError> {
            if case .op(let c) = current, c == "+" || c == "-" {
                _ = advance()
                switch parseUnary() {
                case .success(let v):
                    return .success(c == "-" ? -v : v)
                case .failure(let e):
                    return .failure(e)
                }
            }
            return parsePrimary()
        }

        /// primary := number | '(' expr ')'
        mutating func parsePrimary() -> Result<Double, MathError> {
            switch current {
            case .number(let v):
                _ = advance()
                return .success(v)
            case .op("("):
                _ = advance()
                switch parseExpr() {
                case .success(let v):
                    // 必须有匹配的 ')'
                    if case .op(")") = current {
                        _ = advance()
                        return .success(v)
                    }
                    return .failure(.syntaxError)
                case .failure(let e):
                    return .failure(e)
                }
            default:
                // 不完整表达式 / 非法起始 token
                return .failure(.syntaxError)
            }
        }
    }
}

// MARK: - 模块顶层别名

/// 顶层别名，便于外部（含测试）直接用裸名 `MathError` 引用，无需全限定 `MathEvaluator.MathError`。
typealias MathError = MathEvaluator.MathError
