### [2026-06-28] SettingsSection 枚举新增 case 须同步更新 3 类测试合约

<!-- tags: settings, settings-section, enum, test-contract, allcases, count, ax-id, sidebar, acceptance-test, tab, appkit -->

**Background**: 设置页新增「AI 配置」tab 时，在 `SettingsSection` 枚举加 `case ai` 后 `allCases.count` 从 5 变为 6，导致 3 个测试文件中 10+ 处硬断言（count == 5、rawValue 顺序数组、AX id 集合、排除断言）全部挂掉。这些测试与实现是分离的（红队验收、AX 契约、sidebar 集成测试），plan-reviewer 在初审中捕获为 BLOCKER。

**Lesson**: `SettingsSection` 扩展新 case 时，必须在实现计划中增加 Step 0 预先更新以下 3 个测试文件：

1. **SettingsSidebarTests** — `allCases.count` 硬数字、`rawValues` 顺序数组、排除断言（如 `XCTAssertNil(rawValue: "ai_config")`）
2. **SettingsSidebarAcceptanceTests** — `allCases.count` 硬数字、`numberOfRows` 硬编码（除非已用 `allCases.count` 数据驱动）
3. **SettingsAXContractTests** — `expectedSidebarIDs` 集合须追加 `"settings.sidebar.<newCase>"`、`countIs5` 硬断言

**例外**：`XCTAssertEqual(tableView.numberOfRows, SettingsSection.allCases.count, ...)` 已数据驱动——无需手动修改。

**How to apply**: 任何新增 `SettingsSection` case 的 PR 必须包含上述 3 个测试文件的同步更新。实现计划中应作为 Step 0 显式列出，不可省略。
