# 设计文档: AI 可自我验证测试方案

## 技术方案
引入 `SceneControlling` 协议解耦 SessionManager → BuddyScene，使 MockScene 可注入测试。统一所有测试到 `swift test`，覆盖率从 ~15% → ~65%，执行 <10s。

## 文件影响
| 文件 | 操作 | 说明 |
|------|------|------|
| `Sources/.../Scene/SceneControlling.swift` | 新建 | 7 个方法的协议 |
| `Sources/.../Scene/BuddyScene.swift` | 小改 | 添加协议遵循 |
| `Sources/.../Session/SessionManager.swift` | 中改 | scene 类型改协议；暴露 handle/checkTimeouts/sessions/usedColors |
| `tests/BuddyCoreTests/MockScene.swift` | 新建 | 测试替身 |
| `tests/BuddyCoreTests/TestHelpers.swift` | 新建 | 工厂方法 |
| `tests/BuddyCoreTests/SessionManagerTests.swift` | 新建 | 33 个单元测试 |
| `tests/BuddyCoreTests/SessionManagerAcceptanceTests.swift` | 新建 | 14 个验收测试 |
| `tests/BuddyCoreTests/TranscriptReaderTests.swift` | 新建 | 10 个测试 |
| `tests/BuddyCoreTests/EventBusTests.swift` | 新建 | 4 个测试 |
| `tests/BuddyCoreTests/SessionIntegrationTests.swift` | 新建 | 12 个集成测试 |
| `Makefile` | 小改 | 添加 test-acceptance/test-all |

## 设计决策
1. SceneControlling 使用 CatState（非 EntityState）保持一致性
2. 测试串行假设（swift test 默认 --no-parallel）
3. SocketServer 不需要 mock（init 无副作用，测试不调 start()）
