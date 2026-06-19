import XCTest
@testable import BuddyCore

// MARK: - MathEvaluatorAcceptanceTests
//
// 红队验收测试：MathEvaluator 递归下降求值器契约（ME1–ME6 + 边界/正/反谓词）
//
// 本文件覆盖：
//   ME1  — 二元运算优先级（* 先于 +）、左结合（+/- 同级从左到右）
//   ME2  — 括号覆盖优先级
//   ME3  — 幂运算 ^ 右结合（关键 mutation-killer：2^3^2 == 512 非 64）
//   ME4  — 模 %、一元 +/-、连续一元（--5 / -+5）
//   ME5  — 除零 / 模零 → .failure(.divisionByZero)
//   ME6  — 语法错误 / 字符白名单 invariant（1+ / (1+2 / 1e3 / 1,5 / abc / "" → .empty）
//   ME7  — 格式化契约（format：整数去 .0、浮点噪声抑制、-0.0 → "0"）
//   ME8  — looksLikeComputation 激活门控（裸数字不激活、空串不激活、运算符/括号激活）
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Calculator/ 下任何实现文件
//   - 仅依据设计文档契约逐字断言（接口签名 + 边界值字面量）
//   - 每例强断言（XCTAssertEqual），反 no-op / 反宽容跳过
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// CONTRACT_AMBIGUOUS:
//   1. overflow 触发边界：白名单禁止 'e'，无法构造 1e308*1e308；纯整数大数
//      9999999999^9999999999 是否触发 overflow 取决于实现是否在 pow 阶段检查 isInfinite。
//      本测试优先使用能确定 success 的整数用例，overflow 断言留模糊点注释。
//   2. --5 语义：文法 unary:=('+'|'-') unary 允许连续一元。--5 应等于 5。
//      若实现限制单层一元，此例会变 syntaxError——按文法推导断言 5，留 QA 核对。
//   3. MathEvaluator 命名空间形式：契约写 `enum MathEvaluator` + static 方法，
//      测试用 `MathEvaluator.evaluate(...)` 调用——这是契约命名。

final class MathEvaluatorAcceptanceTests: XCTestCase {

    // MARK: - ME1：二元运算优先级与左结合

    /// ME1：`1+2*3` == 7.0（* 先于 +）
    func test_ME1_multiplicationPrecedenceOverAddition() {
        let result = MathEvaluator.evaluate("1+2*3")
        XCTAssertEqual(result, .success(7.0),
            "ME1: 1+2*3 必须 == 7.0（* 先于 +），实际 \(result)")
    }

    /// ME1：`1+2-3` == 0.0（+/- 同级左结合：((1+2)-3)=0）
    func test_ME1_additionSubtraction_leftAssociative() {
        let result = MathEvaluator.evaluate("1+2-3")
        XCTAssertEqual(result, .success(0.0),
            "ME1: 1+2-3 必须 == 0.0（左结合），实际 \(result)")
    }

    /// ME1 补充：`2*3+4` == 10.0（* 先于 +，左侧先算）
    func test_ME1_multiplicationBeforeAddition_leftSide() {
        let result = MathEvaluator.evaluate("2*3+4")
        XCTAssertEqual(result, .success(10.0),
            "ME1: 2*3+4 必须 == 10.0，实际 \(result)")
    }

    /// ME1 补充：`10-2-3` == 5.0（左结合：((10-2)-3)=5，非右结合的 10-(2-3)=11）
    func test_ME1_subtraction_leftAssociative_notRight() {
        let result = MathEvaluator.evaluate("10-2-3")
        XCTAssertEqual(result, .success(5.0),
            "ME1: 10-2-3 必须 == 5.0（左结合，非右结合的 11），实际 \(result)")
    }

    // MARK: - ME2：括号覆盖优先级

    /// ME2：`(1+2)*3` == 9.0（括号覆盖优先级）
    func test_ME2_parens_overridePrecedence() {
        let result = MathEvaluator.evaluate("(1+2)*3")
        XCTAssertEqual(result, .success(9.0),
            "ME2: (1+2)*3 必须 == 9.0（括号覆盖优先级），实际 \(result)")
    }

    /// ME2 补充：嵌套括号 `((1+2)*(3+4))` == 21.0
    func test_ME2_nestedParens() {
        let result = MathEvaluator.evaluate("(1+2)*(3+4)")
        XCTAssertEqual(result, .success(21.0),
            "ME2: (1+2)*(3+4) 必须 == 21.0（嵌套括号），实际 \(result)")
    }

    // MARK: - ME3：幂运算 ^ 右结合（关键 mutation-killer）

    /// ME3：`2^10` == 1024.0
    func test_ME3_power2to10() {
        let result = MathEvaluator.evaluate("2^10")
        XCTAssertEqual(result, .success(1024.0),
            "ME3: 2^10 必须 == 1024.0，实际 \(result)")
    }

    /// ME3 关键 mutation-killer：`2^3^2` == 512.0（右结合：2^(3^2)=2^9=512，非左结合 (2^3)^2=64）
    ///
    /// Mutation-Survival 自检：
    /// - 左结合 mutant（^ 当作左结合）→ 得 64.0 → 本断言失败（捕获）
    /// - 无优先级 mutant（^ 与 * 同级从左到右）→ 得 64.0 → 本断言失败（捕获）
    func test_ME3_power_rightAssociative_2c3c2() {
        let result = MathEvaluator.evaluate("2^3^2")
        XCTAssertEqual(result, .success(512.0),
            "ME3 (mutation-killer): 2^3^2 必须 == 512.0（^ 右结合：2^(3^2)），实际 \(result)。若得 64 说明实现错误用了左结合")
    }

    /// ME3 补充：`3^2^2` == 81.0（3^(2^2)=3^4=81，非 (3^2)^2=81——碰巧相等，但验证右结合路径）
    func test_ME3_power_rightAssociative_3c2c2() {
        let result = MathEvaluator.evaluate("3^2^2")
        XCTAssertEqual(result, .success(81.0),
            "ME3: 3^2^2 必须 == 81.0（3^(2^2)=3^4），实际 \(result)")
    }

    /// ME3 补充：`2^3^2+1` == 513.0（右结合 + 后续加法，验证 ^ 优先级高于 +）
    func test_ME3_power_rightAssoc_thenAddition() {
        let result = MathEvaluator.evaluate("2^3^2+1")
        XCTAssertEqual(result, .success(513.0),
            "ME3: 2^3^2+1 必须 == 513.0（先算 2^9=512，再 +1），实际 \(result)")
    }

    // MARK: - ME4：模 % 与一元 +/-

    /// ME4：`7%2` == 1.0
    func test_ME4_modulo_7mod2() {
        let result = MathEvaluator.evaluate("7%2")
        XCTAssertEqual(result, .success(1.0),
            "ME4: 7%2 必须 == 1.0，实际 \(result)")
    }

    /// ME4：`8%2` == 0.0
    func test_ME4_modulo_8mod2() {
        let result = MathEvaluator.evaluate("8%2")
        XCTAssertEqual(result, .success(0.0),
            "ME4: 8%2 必须 == 0.0，实际 \(result)")
    }

    /// ME4：`-5` == -5.0（一元负号）
    func test_ME4_unaryMinus() {
        let result = MathEvaluator.evaluate("-5")
        XCTAssertEqual(result, .success(-5.0),
            "ME4: -5 必须 == -5.0（一元负号），实际 \(result)")
    }

    /// ME4：`+5` == 5.0（一元正号）
    func test_ME4_unaryPlus() {
        let result = MathEvaluator.evaluate("+5")
        XCTAssertEqual(result, .success(5.0),
            "ME4: +5 必须 == 5.0（一元正号），实际 \(result)")
    }

    /// ME4：`--5` == 5.0（连续一元：-(-5)=5，按文法 unary:=('+'|'-') unary 推导）
    ///
    /// CONTRACT_AMBIGUOUS: 若实现限制单层一元，此例为 syntaxError。
    /// 按文法推导断言 5.0，留 QA 核对。
    func test_ME4_doubleUnaryMinus() {
        let result = MathEvaluator.evaluate("--5")
        XCTAssertEqual(result, .success(5.0),
            "ME4 (CONTRACT_AMBIGUOUS): --5 按文法 unary:=('+'|'-') unary 应 == 5.0（-(-5)=5），实际 \(result)")
    }

    /// ME4 补充：`-(3+2)` == -5.0（一元负号 + 括号）
    func test_ME4_unaryMinus_withParens() {
        let result = MathEvaluator.evaluate("-(3+2)")
        XCTAssertEqual(result, .success(-5.0),
            "ME4: -(3+2) 必须 == -5.0，实际 \(result)")
    }

    // MARK: - ME5：除零 / 模零

    /// ME5：`1/0` → .failure(.divisionByZero)
    func test_ME5_divisionByZero() {
        let result = MathEvaluator.evaluate("1/0")
        guard case .failure(let err) = result else {
            XCTFail("ME5: 1/0 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .divisionByZero,
            "ME5: 1/0 错误必须 == .divisionByZero，实际 \(err)")
    }

    /// ME5：`5%0` → .failure(.divisionByZero)
    func test_ME5_moduloByZero() {
        let result = MathEvaluator.evaluate("5%0")
        guard case .failure(let err) = result else {
            XCTFail("ME5: 5%0 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .divisionByZero,
            "ME5: 5%0 错误必须 == .divisionByZero，实际 \(err)")
    }

    /// ME5 补充：`0/0` → .failure（除零，具体 .divisionByZero 或 NaN 驱动，断言是 .failure）
    func test_ME5_zeroDividedByZero_isFailure() {
        let result = MathEvaluator.evaluate("0/0")
        if case .success(let v) = result {
            XCTFail("ME5: 0/0 不应 .success(\(v))，必须 .failure（除零）")
        }
    }

    // MARK: - ME6：语法错误 / 字符白名单 invariant

    /// ME6：`1+` → .failure(.syntaxError)（末尾 dangling 运算符）
    func test_ME6_trailingOperator_syntaxError() {
        let result = MathEvaluator.evaluate("1+")
        guard case .failure(let err) = result else {
            XCTFail("ME6: 1+ 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: 1+ 错误必须 == .syntaxError（末尾 dangling 运算符），实际 \(err)")
    }

    /// ME6：`(1+2` → .failure(.syntaxError)（左括号未闭合）
    func test_ME6_unbalancedOpenParen_syntaxError() {
        let result = MathEvaluator.evaluate("(1+2")
        guard case .failure(let err) = result else {
            XCTFail("ME6: (1+2 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: (1+2 错误必须 == .syntaxError（括号未闭合），实际 \(err)")
    }

    /// ME6：`1+2)` → .failure(.syntaxError)（多余右括号）
    func test_ME6_unbalancedCloseParen_syntaxError() {
        let result = MathEvaluator.evaluate("1+2)")
        guard case .failure(let err) = result else {
            XCTFail("ME6: 1+2) 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: 1+2) 错误必须 == .syntaxError（多余右括号），实际 \(err)")
    }

    /// ME6：`1e3` → .failure(.syntaxError)（'e' 非白名单，禁科学计数法）
    func test_ME6_scientificNotation_e_syntaxError() {
        let result = MathEvaluator.evaluate("1e3")
        guard case .failure(let err) = result else {
            XCTFail("ME6: 1e3 必须 .failure（'e' 非白名单），实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: 1e3 错误必须 == .syntaxError（'e' 非白名单字符），实际 \(err)")
    }

    /// ME6：`1,5` → .failure(.syntaxError)（',' 非白名单）
    func test_ME6_comma_syntaxError() {
        let result = MathEvaluator.evaluate("1,5")
        guard case .failure(let err) = result else {
            XCTFail("ME6: 1,5 必须 .failure（',' 非白名单），实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: 1,5 错误必须 == .syntaxError（',' 非白名单字符），实际 \(err)")
    }

    /// ME6：`abc` → .failure(.syntaxError)（字母非白名单）
    func test_ME6_letters_syntaxError() {
        let result = MathEvaluator.evaluate("abc")
        guard case .failure(let err) = result else {
            XCTFail("ME6: abc 必须 .failure（字母非白名单），实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: abc 错误必须 == .syntaxError（字母非白名单），实际 \(err)")
    }

    /// ME6：`""`（空串）→ .failure(.empty)
    func test_ME6_emptyString_emptyError() {
        let result = MathEvaluator.evaluate("")
        guard case .failure(let err) = result else {
            XCTFail("ME6: \"\" 必须 .failure，实际 \(result)")
            return
        }
        XCTAssertEqual(err, .empty,
            "ME6: \"\" 错误必须 == .empty（空输入），实际 \(err)")
    }

    /// ME6：`1+2 3` → .failure(.syntaxError)（两个数字无运算符连接，空格分隔）
    func test_ME6_twoNumbersNoOperator_syntaxError() {
        let result = MathEvaluator.evaluate("1+2 3")
        guard case .failure(let err) = result else {
            XCTFail("ME6: 1+2 3 必须 .failure（两个数字无运算符），实际 \(result)")
            return
        }
        XCTAssertEqual(err, .syntaxError,
            "ME6: 1+2 3 错误必须 == .syntaxError，实际 \(err)")
    }

    // MARK: - ME6 补充：overflow（CONTRACT_AMBIGUOUS）

    /// CONTRACT_AMBIGUOUS: 纯数字白名单下 overflow 触发边界未明确。
    /// 大数幂 `999^999` 理论上会产生 isInfinite（~10^2997 远超 Double 范围），
    /// 但实现是否在 pow 阶段检查 isInfinite 并映射 .overflow，或返回 .success(.infinity)，
    /// 契约未明确（"无穷/NaN → 不出候选" 是 plugin 层门控，evaluator 层可能返回 infinity）。
    /// 本测试断言"要么 .success 要么 .failure"（不 crash），具体 case 留 QA 核对。
    func test_ME6_largePower_doesNotCrash_successOrFailOnly() {
        let result = MathEvaluator.evaluate("999^999")
        switch result {
        case .success:
            // 实现允许大数幂（可能返回 infinity）——plugin 层门控会过滤
            break
        case .failure:
            // 实现主动检测 overflow / infinity 并映射错误 case——具体 case 留 QA 核对
            break
        }
    }

    // MARK: - ME7：格式化契约

    /// ME7：format(4.0) == "4"（整数去 .0）
    func test_ME7_format_integer_dropsTrailingZero() {
        XCTAssertEqual(MathEvaluator.format(4.0), "4",
            "ME7: format(4.0) 必须 == \"4\"（整数去 .0）")
    }

    /// ME7：format(0.30000000000000004) == "0.3"（浮点噪声抑制）
    func test_ME7_format_floatNoiseSuppressed() {
        XCTAssertEqual(MathEvaluator.format(0.30000000000000004), "0.3",
            "ME7: format(0.30000000000000004) 必须 == \"0.3\"（浮点噪声抑制）")
    }

    /// ME7：format(-0.0) == "0"（负零归一为 "0"）
    func test_ME7_format_negativeZero_becomesZero() {
        XCTAssertEqual(MathEvaluator.format(-0.0), "0",
            "ME7: format(-0.0) 必须 == \"0\"（负零归一），实际 \"\(MathEvaluator.format(-0.0))\"")
    }

    /// ME7：format(3.14) == "3.14"（正常小数保留）
    func test_ME7_format_normalDecimal() {
        XCTAssertEqual(MathEvaluator.format(3.14), "3.14",
            "ME7: format(3.14) 必须 == \"3.14\"")
    }

    /// ME7：format(10.0) == "10"（整数去 .0，多位）
    func test_ME7_format_integer10_dropsTrailingZero() {
        XCTAssertEqual(MathEvaluator.format(10.0), "10",
            "ME7: format(10.0) 必须 == \"10\"")
    }

    /// ME7 补充：format(-5.0) == "-5"（负整数）
    func test_ME7_format_negativeInteger() {
        XCTAssertEqual(MathEvaluator.format(-5.0), "-5",
            "ME7: format(-5.0) 必须 == \"-5\"")
    }

    // MARK: - ME8：looksLikeComputation 激活门控

    /// ME8：`"1+1"` → true（含 + 运算符）
    func test_ME8_looksLikeComputation_addition_true() {
        XCTAssertTrue(MathEvaluator.looksLikeComputation("1+1"),
            "ME8: looksLikeComputation(\"1+1\") 必须 == true（含 +）")
    }

    /// ME8：`"365"` → false（裸数字，无运算符/括号——防劫持 AppLauncher）
    func test_ME8_looksLikeComputation_bareNumber_false() {
        XCTAssertFalse(MathEvaluator.looksLikeComputation("365"),
            "ME8: looksLikeComputation(\"365\") 必须 == false（裸数字不激活，防劫持 AppLauncher）")
    }

    /// ME8：`"2^3"` → true（含 ^）
    func test_ME8_looksLikeComputation_power_true() {
        XCTAssertTrue(MathEvaluator.looksLikeComputation("2^3"),
            "ME8: looksLikeComputation(\"2^3\") 必须 == true（含 ^）")
    }

    /// ME8：`"(1+2)"` → true（含括号）
    func test_ME8_looksLikeComputation_parens_true() {
        XCTAssertTrue(MathEvaluator.looksLikeComputation("(1+2)"),
            "ME8: looksLikeComputation(\"(1+2)\") 必须 == true（含括号）")
    }

    /// ME8：`"-5"` → false（仅一元负号，无二元运算符/括号——按契约只激活二元运算符或括号）
    ///
    /// CONTRACT_AMBIGUOUS: 契约写"仅当 query 含运算符字符（+ - * / % ^ 或 (）"，
    /// 若 - 算激活字符则 -5 → true。但设计意图"裸数字不激活"暗示 -5（单数字负号）
    /// 应不出候选。按设计意图断言 false，留 QA 核对实现是否区分一元 vs 二元。
    func test_ME8_looksLikeComputation_unaryMinusOnly_false() {
        XCTAssertFalse(MathEvaluator.looksLikeComputation("-5"),
            "ME8 (CONTRACT_AMBIGUOUS): looksLikeComputation(\"-5\") 按设计意图应 == false（单数字负号不出候选），实际 \(MathEvaluator.looksLikeComputation("-5"))")
    }

    /// ME8：`"abc"` → false（字母，无运算符）
    func test_ME8_looksLikeComputation_letters_false() {
        XCTAssertFalse(MathEvaluator.looksLikeComputation("abc"),
            "ME8: looksLikeComputation(\"abc\") 必须 == false")
    }

    /// ME8：`""` → false（空串）
    func test_ME8_looksLikeComputation_empty_false() {
        XCTAssertFalse(MathEvaluator.looksLikeComputation(""),
            "ME8: looksLikeComputation(\"\") 必须 == false（空串）")
    }

    /// ME8：`"1 2"` → false（仅空格，无运算符）
    func test_ME8_looksLikeComputation_spacesOnly_false() {
        XCTAssertFalse(MathEvaluator.looksLikeComputation("1 2"),
            "ME8: looksLikeComputation(\"1 2\") 必须 == false（仅空格分隔数字，无运算符）")
    }

    /// ME8 补充：`"7%2"` → true（含 %）
    func test_ME8_looksLikeComputation_modulo_true() {
        XCTAssertTrue(MathEvaluator.looksLikeComputation("7%2"),
            "ME8: looksLikeComputation(\"7%2\") 必须 == true（含 %）")
    }
}
