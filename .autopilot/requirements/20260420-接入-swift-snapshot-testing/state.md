---
active: true
phase: "merge"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/sleepy-forging-toucan/.autopilot/requirements/20260420-接入-swift-snapshot-testing"
session_id: b8885ab6-090d-45da-98bf-2af753e66740
started_at: "2026-04-20T15:37:07Z"
---

## 目标
接入 swift-snapshot-testing 然后完成所有用例的编写，并在当前 claude.md 里说明，确保后续的 autopilot 验证里都包含相关用例的编写

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标
接入 swift-snapshot-testing 库，为 SkinCardItem（AppKit）、SkinGalleryViewController（AppKit）、CatSprite 各状态（SpriteKit）编写快照测试，并更新 CLAUDE.md 确保后续开发包含快照测试。

### 技术方案
1. SPM 依赖接入: Package.swift 新增 swift-snapshot-testing (>=1.17.0)
2. AppKit 视图快照: 直接对 NSView 调用 `assertSnapshot(of:as:.image(size:))`
3. SpriteKit 快照: SKView + presentScene + texture(from:) 离屏渲染
4. 录制保护: 首次运行自动录制，后续比对

### 风险缓解
- SpriteKit 纹理缺失 → orange placeholder 兜底
- NSProgressIndicator 动画不稳定 → 快照前 stopAnimation
- Gallery 网络依赖 → catalogURL 设为必失败 URL
- NSCollectionView 离屏不渲染 → 加入临时 NSWindow

## 实现计划

- [ ] 1. 修改 Package.swift 添加 swift-snapshot-testing 依赖
- [ ] 2. 创建 SnapshotTestHelpers.swift（mock manifest、SKView 辅助、临时 window）
- [ ] 3. 编写 SkinCardSnapshotTests.swift（6 用例）
- [ ] 4. 编写 SkinGallerySnapshotTests.swift（2-3 用例）
- [ ] 5. 编写 CatSpriteSnapshotTests.swift（6 用例）
- [ ] 6. 录制模式生成基线
- [ ] 7. 验证 make test 全部通过
- [ ] 8. 更新 CLAUDE.md

## 红队验收测试
- tests/acceptance/test-snapshot-testing.acceptance.sh — 验证 SPM 依赖、文件存在、编译、录制、稳定性、全量回归

## QA 报告

### Wave 1 — 编译与测试
| 检查项 | 结果 | 证据 |
|--------|------|------|
| `swift build --build-tests` | ✅ | Build complete! (0.85s) |
| `swift test` 全量通过 | ✅ | 406 tests, 0 failures |
| `swift test --filter Snapshot` 稳定 | ✅ | CatSprite 5/5 连续通过，SkinCard/Gallery 全部稳定 |
| `make lint` | ✅ | 0 violations |

### Wave 2 — 产出物验证
| 检查项 | 结果 | 证据 |
|--------|------|------|
| Package.swift 依赖正确 | ✅ | swift-snapshot-testing from "1.17.0" + SnapshotTesting product |
| 4 个测试文件存在 | ✅ | SnapshotTestHelpers/SkinCard/Gallery/CatSprite |
| 基线 PNG 14 张生成 | ✅ | __Snapshots__/ 下 3 个子目录，共 14 个 .png |
| __Snapshots__ 未被 gitignore | ✅ | .gitignore 无 snapshot 相关条目 |
| CLAUDE.md 更新快照说明 | ✅ | 包含覆盖范围、使用规范、autopilot 集成说明 |

### 结论
全部 ✅ 通过。

## 变更日志
- [2026-04-20T16:08:05Z] 用户批准验收，进入合并阶段
- [2026-04-20T15:37:07Z] autopilot 初始化，目标: 接入 swift-snapshot-testing 然后完成所有用例的编写，并在当前 claude.md 里说明，确保后续的 autopilot 验证里都包含相关用例的编写
- [2026-04-20T15:45:00Z] design 阶段完成，方案通过审批，进入 implement 阶段
- [2026-04-21T00:02:00Z] implement 完成：Package.swift + 4 个测试文件 + CLAUDE.md 更新。406 tests 0 failures。进入 QA
- [2026-04-21T00:05:00Z] QA 全部通过，等待审批合并
