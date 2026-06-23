# autopilot 红队 agent 可能虚假报告（acceptance 文件未落盘却声称成功），编排器必须 find 验证

<!-- tags: autopilot, red-team, false-report, verification, find, ls, worktree, file-existence, contract-ambiguous, seam-mismatch, orchestration, implement, qa, sub-agent -->

**Scenario**: implement 阶段红队 agent 返回详细报告（"2 个 acceptance 文件、43 个测试、谓词映射表"），但 `find . -name '*.acceptance.test.swift' -path '*Paste*'` 全仓库搜索返回**空**——文件根本没落盘（红队写到了主仓库路径而非 worktree，或 Write 调用失败未重试）。若编排器不验证就合流，会带"假红队测试"进 QA，Tier 0 红队验收形同虚设。

**Lesson**:

1. **红队报告不可信，必须 find 验证文件落盘**——编排器收到红队产出后，立即：
   ```bash
   find . -name '*.acceptance.test.*' -not -path '*/node_modules/*' -path '*<module>*'
   ```
   空结果 = 红队虚假报告，必须重跑。不能信报告里的"文件列表 + 测试数"声明。

2. **worktree 路径混淆**——红队 agent 可能把文件写到主仓库（`~/workspace_sync/.../apps/...`）而非当前 worktree（`~/.claude/worktrees/<wt>/apps/...`）。重跑 prompt 必须：给 worktree 绝对路径 + 明确禁止主仓库路径 + 要求 Write 后 `ls -la <dir>` 验证文件在输出里 + 返回报告附 ls 输出作落盘证据。

3. **CONTRACT_AMBIGUOUS 合流修复**——红队/蓝队对未在契约明确的 seam 签名（如 PastePlugin `init` 参数顺序、`historyService` 访问性）各自假定，编译失败。编排器（不受红队-蓝队信息隔离约束）需统一：让双方对齐到合理 seam。pasteboard 任务修了 6 处：
   - init 参数顺序对齐（`init(historyService:copyService:)`）
   - `historyService` 改 `internal`（testable，module 内可见生产无影响）
   - 红队编造的不存在 API（`NSPasteboard.ReadingOptionBridge`）→ 正确 `[NSURL.self]`
   - 红队 PP13 断言方向反（`LessThan` 应 `GreaterThan`，红队自承认）
   - 蓝队 previewTitle 截断边界（前 50+…=51 → 前 49+…=50）
   - 红队 scenario4 加显式 `load()`（init 不自动 load，生产由 startMonitoring 触发）/ scenario5.P3 先落盘正常内容再测排除（precondition 缺陷）

4. **红队还可能编造不存在的 API**（如 `NSPasteboard.ReadingOptionBridge`）——编译会暴露，编排器需在合流时 build-tests 验证红队文件可编译，grep 确认 API 真实性。

5. **scenario 监控 gap**——红队可能漏测某场景的端到端（如 scenario8 只测 startMonitoring 幂等，没测"复制→Timer→捕获"）。QA Tier 1.5 场景计数匹配（E=N）能发现，编排器补 gap 测试。

**Rationale**: autopilot 红蓝对抗依赖信息隔离的独立验收。红队虚假报告 = 验收失效 = 抽卡来源。编排器是最后一道防线，必须用 find/ls/build-tests 验证红队产出真实存在、可编译、覆盖全场景，不能信报告声明（"成功都需要证据"铁律）。

**Evidence**: pasteboard 任务 implement 阶段，红队首次报告虚假（find 全仓库搜 Paste acceptance 返回空）→ 重跑明确 worktree 绝对路径 + Write 后 ls 验证 → 落盘成功（28297+27761 字节）；合流修 6 处 CONTRACT_AMBIGUOUS → 91 tests 全绿；scenario8 monitoring gap → QA 补 `test_scenario8_monitoring_capturesNewContent` 端到端测试。

**关联**: [[nspasteboard-clipboard-history-monitoring-builtin-plugin]]（本任务 PastePlugin 落地，触发本教训）、autopilot anti-rationalization 指南（红队跳过/放宽断言的借口与真相）、[[qa-e2e-verification]]（QA 必须真实 E2E 验证 memory）
