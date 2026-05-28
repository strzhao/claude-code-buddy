# 007-e2e-and-docs handoff

## 实现摘要

task 007 是 Launcher DAG 的最后一棒：通过 SC 覆盖矩阵证实 12 个验收场景中 11 个已被现有 856 tests 覆盖，**仅 SC-10 (Launcher 与像素猫互不干扰)** 需要新建。落点：

- **蓝队** `LauncherIsolationTests.swift` (4 测试，静态契约断言)：路径不重叠 / LauncherManager 不引用像素猫类型 / 不修改全局 NSApp / TrustStore 路径独立
- **红队** `LauncherIsolationAcceptanceTests.swift` (4 测试，独立视角对抗)：路径集合 Set.intersection / 全 Launcher 子目录递归 grep / buddyDir 必须以 NSHomeDirectory() 开头 / 无硬编码 `/tmp/claude-buddy` 字面量
- 文档：apps/desktop/CLAUDE.md + 根级 CLAUDE.md + README.md + .autopilot/project/sc-coverage.md
- 验证：864 tests / 0 failures (54.3s), 0 lint violations, 5/5 Tier 1.5 真实场景 PASS, qa-reviewer Ready to merge

## 关键文件路径

```
apps/desktop/Tests/BuddyCoreTests/Launcher/
├── LauncherIsolationTests.swift              # [新] 蓝队 4 静态契约测试 (#filePath 上溯 4 层)
└── LauncherIsolationAcceptanceTests.swift    # [新] 红队 4 独立视角测试 (#file 上溯 4 层 + 递归 enumerator)

apps/desktop/CLAUDE.md       # [改] +`## Launcher 子系统` 章节（配置/插件/TOFU/排查）
CLAUDE.md (根级)              # [改] +`### Launcher CLI` 命令 + 子项目入口
README.md                    # [改] +Launcher 启动器（v0.25+）简介
.autopilot/project/sc-coverage.md  # [新] 12 SC 覆盖矩阵归档（864 tests 末态）
```

## 下游须知（v2+）

task 007 已收尾整个 Launcher 子系统 MVP。后续增强方向（不在本 DAG）：

1. **持久会话与上下文压缩**：当前 SC-08 每次唤起新 session，v2 可加 `--continue` 复用上轮 sessionId
2. **TOFU v2 "信任未来版本"选项**：当前 trustKey 含 exe bytes hash，每次升级都重弹 NSAlert（UX 略噪），可加可信任此 repo 整体的选项
3. **Tier 5 量化指标**：当前 Swift 项目无 Stryker mutation / c8 coverage 工具，`/autopilot doctor` 建议探索 SwiftSyntax 衍生方案
4. **LauncherProvider.send 协议加 `system: String?` 参数**：避免 router prompt 拼 user message 前缀（task 005 backlog #2）

## 设计偏差（已确认合理）

1. **副作用清单文字小漂移**：设计文档前半段写"新增 1 测试文件"，实际新增 2 个（蓝队 + 红队）。设计文档 `## 红队验收测试` 章节明确规划了红队产出，仅前半段未同步更新。qa-reviewer 标记 ⚠️ 不阻塞。
2. **红队测试 `#file` 上溯层数**：初版 3 层（错误，导致 2/4 测试被 XCTSkip），修正为 4 层后 8/8 全 PASS。**经验**：`#file` 测试源文件 → 项目根目录的层数等于路径中的 `/` 分隔目录数，必须以实际目录结构计数（`tests/BuddyCoreTests/Launcher/<file>` → 4 层 deletingLastPathComponent 到 `apps/desktop/`）。
3. **provider ID 统一为 `anthropic`**：plan-reviewer suggestion 1 推荐统一示例（设计模板原本 `anthropic-1` / `anthropic` 混用），文档实现采用更简洁的 `anthropic`，与真实使用习惯一致。
4. **contract_required true→false 校正**：state.md frontmatter 初始 true，但 brief 文件本身 false（task 007 仅 test+docs 无 API 契约规约）。已校正为 false，跳过 contract-checker。

## 已知 backlog（非阻塞）

1. Tier 5 mutation/coverage 指标对 Swift 项目缺工具支持
2. sc-coverage.md 测试计数初版 858（基于"+2 isolation"误算），qa-reviewer 发现并修正为 864（实际 +8 tests = 蓝 4 + 红 4）
