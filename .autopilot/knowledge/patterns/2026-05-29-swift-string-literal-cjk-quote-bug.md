# Swift 字符串字面量混用 ASCII 双引号包含中文文本会触发隐晦编译错误

<!-- tags: swift, string-literal, double-quote, cjk, xctest, compilation-error, escape, red-team-test, message-string -->

**Scenario**: task 002 红队 sub-agent 写 XCTest 验收测试时，多个测试断言消息用如下风格描述："必须含某字段名"：

```swift
XCTAssertTrue(
    reason.contains("绝对路径"),
    "错误信息必须含"绝对路径"，实际: \(reason)"   // ⚠️ 编译错误
)
```

Swift 编译报 `missing argument label 'file:' in call`——错误信息**完全误导**实际是 Swift 把第二个 `"` 看作字符串终结（"错误信息必须含" 是完整字符串），后面 `绝对路径` 当作未声明标识符，第三个 `"` 又开始新字符串。结果整个 XCTAssertTrue 调用结构被打散，parser 找不到 `file:` 参数标签。

**Lesson**: Swift 字符串字面量用 ASCII `"` 时**绝对不能**在内容里直接放 ASCII `"`，必须 `\"` 转义。但中文环境下写测试消息天然想用引号强调字段名，常见踩坑模式：

```swift
// ❌ 错误：ASCII " 误终结字符串
"必须含"字段名"，实际: \(actual)"

// ✅ 修复方式 1：转义
"必须含 \"字段名\"，实际: \(actual)"

// ✅ 修复方式 2：改用中文方头括号「」
"必须含「字段名」，实际: \(actual)"

// ✅ 修复方式 3：完全去掉引号，加"字样"等限定词
"必须含 字段名 字样，实际: \(actual)"
```

**预防**：
- 写测试消息时优先方案 3（最简洁，无歧义）
- code review / lint 阶段 grep 模式 `'"[^"]*"[^"]*"[^"]*"'`（4+ 双引号同行）找潜在踩坑点
- subagent prompt 模板可在测试样例里显式提示"不要在 ASCII 引号字符串内放 ASCII 引号"

**Evidence**: task 002 红队产出的 PluginManifestModeDiscriminatedUnionAcceptanceTests.swift 文件中有 3 处该 bug（line 178/207/304），编译失败时 swift 报"missing argument label 'file:'"完全误导，靠 Read 实际文件才定位。统一改为方案 3（去引号 + 字样后缀）后 127 测试 0 failure 通过。

**关联**：
- Anti-Overfitting：此 bug 与"中文 commit message subject 首字母大小写规则"（task 001 commitlint 经验）同属"中文环境踩 Swift/lint 工具默认规则"类
- 对子 agent 提示工程的启示：subagent 写代码时不会自检字符串字面量边界，应在 prompt 中给反面例子
