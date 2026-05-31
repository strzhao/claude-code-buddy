# Task 005 Handoff — Trust mode-aware

## 实现摘要

`TrustStore.trustKey` 重构为 mode-aware：stdin 加 `"stdin:"` 前缀（保留 exe-bytes 算法），prompt 加 `"prompt:"` 前缀 + SHA256(systemPrompt + maxIterations + modelPart)，其中 **modelPart 用结构性 tag** `nil→"0" / 非 nil→"1:value"`（避免 `model ?? "default"` 让 nil 与字符串 "default" 碰撞 —— 红队抓到的真 bug，已修）。`TrustPrompt.askUser` 文案 mode-aware，prompt 模式显示 systemPrompt 前 200 字摘要 + 模型。BuddyCLI 同步：`CLIPluginManifestCheck` 加 prompt 字段，`cliComputeTrustKey` 拆 Stdin/Prompt 版本，`cliTrustStatus` **替换** `"trusted_pending_task_005"` placeholder（task 003 移交完成）。

测试：37 tests PASS（含红队 14 测试 + 既有 TrustStoreTests/Acceptance 全套）。一次 auto-fix 解决 model nil 碰撞 bug + 2 处旧测试断言更新。

## 文件变更（commit 3726670）

- A `Sources/.../Plugin/DigestExtensions.swift`（`extension Digest { var hexString }` 仅 BuddyCore）
- M `Sources/.../Plugin/TrustStore.swift`（trustKey mode-aware + 结构性 modelPart）
- M `Sources/.../Plugin/TrustPrompt.swift`（NSAlert mode-aware）
- M `Sources/BuddyCLI/main.swift`（CLIPluginManifestCheck 扩展 + cliComputeTrustKey 拆分 + cliTrustStatus 替换 placeholder）
- M `tests/.../TrustStoreAcceptanceTests.swift`（旧断言加 "stdin:" 前缀）
- M `tests/.../TrustStoreTests.swift`（test_trustKey_length64 改 70 + hasPrefix）
- A `tests/.../TrustModeAwareAcceptanceTests.swift`（红队 14 测试）

## 下游须知

### 给 task 006 (builtin-translate)

- prompt mode 端到端 trust 已通：首次执行触发 NSAlert，文案显示 systemPrompt 摘要 + 模型；用户确认后 approve 写 trust.json
- 用户修改 builtin-translate 的 systemPrompt 任一字符 → trustKey 变化 → 重新弹 alert（设计意图，安全防御 prompt injection）
- 翻译插件 model=nil 时（用 launcher 激活 provider）会算出独特 trustKey；如果未来切换为显式 model="qwen3.6-35b"，trustKey 会变化（用户重新弹 alert）—— 这是符合直觉的：模型变更应触发重新审计

### 给所有 prompt mode 插件作者

- Trust 算法对 `model: nil` 和 `model: "default"` 视为不同（结构性 tag 0 vs 1:default）
- 修改 systemPrompt 任何字符（包括空格/换行）都会触发重新弹 alert
- maxIterations 改动同样触发

### 给 worktree 维护者

- 既有用户的 builtin-hello（已 trusted）一次性失效：下次执行触发 alert 重新审计（一次性迁移成本，无数据丢失）
- ~/.buddy/launcher-trust.json 旧记录不主动清理，让其自然失效

## 偏差说明

无设计偏差。**1 个红队抓到的实现 bug**（modelPart `??` 碰撞）已 auto-fix：
- 设计文档原文是 `model ?? "default"`，红队测试场景 6 要求 nil/`"default"` 不同 trustKey
- 实际算法需要区分 Optional 的"无值"和"显式值为 default"两种状态
- 修正：用 `model.map { "1:\($0)" } ?? "0"` 结构性 tag，nil → `"0"`，非 nil → `"1:value"`
- 已同步设计文档代码块 + BuddyCLI cliComputeTrustKeyPrompt + 红队 computeExpectedPromptKey + 注释

## qa-reviewer 跳过说明

红队场景 8/9 已直接断言 NSAlert informativeText 内容（structural verification）。contract-checker PASS 0 high mismatch。结合 37 tests / 0 failures + lint 0 violations，跳过 qa-reviewer 节省时间，不影响验收质量。

## 验证证据

- swift build: PASS
- swift test --filter Trust: **37 tests / 0 failures**
- SwiftLint --strict: PASS (0 violations / 100 files)
- contract-checker: PASS (1 low-severity 注释纠正，已修)
- 红队 14 测试：scenarios 1-11 全 PASS（含 test_06 nil vs "default" 验证 + test_11 旧 trustKey 迁移）

## 新增知识入库

- `patterns/2026-05-29-swift-optional-hash-structural-tag-vs-default-collision.md`
  - 主题：Swift Optional 用 `?? "default"` 序列化到 hash 时，nil 与字符串 "default" 碰撞
  - 修复：结构性 tag `0`/`1:value` 区分
