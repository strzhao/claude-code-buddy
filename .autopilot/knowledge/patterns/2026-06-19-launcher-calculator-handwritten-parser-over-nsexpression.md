# launcher 计算器用纯 Swift 递归下降求值器，而非 NSExpression（char 白名单防注入 + 纯函数可测）

<!-- tags: launcher, calculator, math-evaluator, recursive-descent, parser, nsexpression, javascriptcore, security, char-whitelist, injection-prevention, pure-function, testability, tofu, builtin-plugin, swift, operator-precedence, right-associative -->

**Scenario**: 第三个内置插件 CalculatorPlugin 需要把用户输入的数学表达式字符串（`1+2*3`、`2^3^2`）求值成 Double。三个候选方案：

1. `NSExpression`（Foundation 内建）——一行代码 `expressionValue(with:context:)`
2. `JavaScriptCore`（WebKit）——`JSContext.evaluateScript`
3. 手写递归下降解析器（~120 行 Swift）

**Lesson**: 选 **3（手写）**，拒 NSExpression / JS。项目有 TOFU 安全模型（外部插件首次执行弹框 + trust 校验），对任意代码注入零容忍，这决定了求值器的安全基线：

| 方案 | 注入面 | 可测性 | 语义控制 | 结论 |
|------|--------|--------|----------|------|
| NSExpression | `FUNCTION()` 可调 selector；默认 context 下有函数调用入口 | 隐式行为，locale/版本敏感 | 优先级/`^` 语义不直观 | ❌ |
| JavaScriptCore | 完整 JS 运行时，任意代码执行 | 黑盒 | JS 语义（`^` 是 XOR 不是幂） | ❌ |
| 手写递归下降 | **零**（char 白名单拒一切字母/函数名） | 纯函数 `Result<Double, MathError>` | 完全自控 | ✅ |

**安全关键设计——char 白名单而非黑名单**：求值前校验输入字符集仅含 `[0-9 . + - * / % ^ ( ) 空格]`，**任意字母（含 `e`、函数名）→ `.syntaxError`**。这从结构上杜绝注入——纯算术文法根本不接受标识符/函数调用，无需枚举攻击向量。白名单 > 黑名单（NSExpression 的加固通常是黑名单过滤危险函数，仍可能遗漏）。

**How to apply**:
- 文法（优先级低→高）：`expr := term (('+'|'-') term)*` → `term := factor (('*'|'/'|'%') factor)*` → `factor := unary ('^' factor)?`（**`^` 右结合**：`parseFactor` 递归调自身，`2^3^2`=`2^(3^2)`=512）→ `unary := ('+'|'-') unary | primary` → `primary := number | '(' expr ')'`。
- 错误用 `Result<Double, MathError>`（`empty/syntaxError/divisionByZero/overflow`），**不抛异常**；`x/0` `x%0` 在 term 层拦 `divisionByZero`，最终结果 `isInfinite||isNaN` → `overflow`。
- 纯函数放 `enum MathEvaluator` 命名空间（无 case、零实例状态、零 AppKit 依赖），镜像 `AppMatcher`（纯函数打分）的可测模式。`@MainActor` 只在 `CalculatorPlugin`（聚合层）。
- 激活门控 `looksLikeComputation` 与求值解耦：插件层先判"含运算符才激活"（裸数字 `365` → 不出候选，让 AppLauncher 接管，避免劫持数字类 app 搜索），再调 `evaluate`。

**Evidence**: 2026-06-19 CalculatorPlugin 合入。`MathEvaluatorAcceptanceTests` 43 例（优先级/括号/`^`右结合 mutation-killer/模/除零/char 白名单拒 `1e3`/format 截尾零）全 PASS；E2E 真机 `1+2*3`→7、`9/2`→4.5 验证。

**关联**：
- [[2026-05-30-launcher-builtin-plugin-direct-action-pipeline]]（决策）：内置插件"直接动作绕过 LLM"的总架构，CalculatorPlugin 是其第三个实例。
- 通用模式：用户可控字符串需要"求值/解释"时，优先手写受限文法（白名单字符集）而非宿主表达式引擎——尤其当 app 已有 TOFU / 信任模型。
