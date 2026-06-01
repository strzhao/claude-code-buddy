# 测试中不应硬编码常量值来查找节点

<!-- tags: testing, constants, spritekit, font-size -->
**Scenario**: 单元测试通过 fontSize==9 来查找 SpriteKit 标签节点，当常量从 9 改为 12 后测试全部崩溃
**Lesson**: 测试中查找节点应引用常量（如 CatConstants.Visual.tabLabelFontSize）而非硬编码魔法数字。常量变更时测试自然会使用新值，无需逐个修改。
**Evidence**: CatSpriteTabNameTests.swift 中 4 处硬编码 fontSize==9 和 fontSize==11，常量改为 12/14 后 6 个测试失败。修复后使用 CatConstants.Visual.tabLabelFontSize 引用。
