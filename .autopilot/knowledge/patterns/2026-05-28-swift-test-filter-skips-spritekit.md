# swift test 按模块 filter 跳过 SpriteKit/Snapshot 节省 97% 时间

<!-- tags: swift-test, spm, filter, qa, performance, spritekit, snapshot-testing, buddy-launcher, ci-time -->

**Scenario**: claude-code-buddy macOS app 的 `swift test` 全量跑（含 SpriteKit + swift-snapshot-testing 套件）一次 ~626 秒（10.4 分钟）。autopilot QA 阶段每次都跑全量浪费时间，且非 SpriteKit task（如 Launcher Provider/Router/Plugin）的改动根本不会影响 SpriteKit 测试结果。

**Lesson**: Swift Package Manager 自 5.7+ 原生支持 `--filter <pattern>` 和 `--skip <pattern>` 参数，pattern 按 test class 名或 test function 名做子串匹配。本工程的最佳实践：

```bash
# 白名单：仅跑特定模块
swift test --filter Provider --filter Router --filter Agent
# Launcher 系列只需 ~17.5 秒（节省 97%）

# 黑名单：排除最慢的 SpriteKit/Snapshot 类
swift test --skip Snapshot --skip CatSprite
```

各 task 应按改动范围声明 QA scope。本工程 task brief 模板已加 `## QA scope` 章节，建议每个 task：
- 纯业务后端类（Provider/Plugin/Trust/Manager）→ filter 对应模块名
- UI/SpriteKit 类（CatSprite/SkinCard）→ filter Snapshot
- 跨多模块的端到端 → make run + 手动验证 + `--skip Snapshot`（avoid 重复 UI 测试）

**Evidence**: task 001 (LauncherProvider system 字段) QA Wave 1 用 `swift test --filter Provider --filter Router --filter Agent` 跑了 131 个测试 17.5 秒（全量 626 秒会跑 N 倍 SpriteKit 快照），唯一 ⚠️ 是预存 D1 测试隔离 bug（与 task 无关）。后续 task 002-006 brief 已同步加 `## QA scope` 章节锁定 filter 范围。

**反面**：盲跑 `swift test` 全量在每个 task 的 QA + auto-fix 重试 + Wave 1.5 retry 上累计浪费时间能到小时级，autopilot 项目模式跑 6 task 至少 6 次 QA，节省的时间能差 10 倍。

**陷阱**：
- `--filter` 是子串匹配，名字过于通用（如 `--filter Test`）会命中太多无关测试
- 部分测试用例需要 SpriteKit + AppKit 真实环境，filter 后跑出绿色不等于全量也绿色——发布前一次全量 baseline 仍然必要
- `--filter` 在 swift-testing（`@Test` 注解，非 XCTest）下匹配规则略不同，本工程当前主要走 XCTest，无影响
