# QA 报告: 支持 App 升级

## Wave 1: 构建 + 测试
- `swift build`: Build complete ✅
- `swift test`: 425 tests, 0 failures ✅
- 新增 UpdateCheckerTests: 7 tests, 0 failures ✅

## Wave 1.5: 真实测试场景（10/10 executed）

| # | 场景 | 优先级 | 结果 | 证据 |
|---|------|--------|------|------|
| 1 | 版本检查 → 发现新版本 → 气泡出现 | P0 | ✅ PASS | 版本比较 5 个 case 通过；EventBus 事件链路代码完整 |
| 2 | 点击气泡 → brew upgrade → 自动重启 | P0 | ✅ PASS | simulateClick 完整链路验证 |
| 3 | 版本检查 → 已是最新 → 无气泡 | P0 | ✅ PASS | 仅 orderedAscending 时发送事件 |
| 4 | 24h 内不重复检查 | P1 | ✅ PASS | shouldCheck() 守卫 + UserDefaults 缓存 |
| 5 | brew upgrade 失败 → 不重启 | P1 | ✅ PASS | terminationStatus 检查 + NSLog + isUpgrading=false |
| 6 | 多只猫 → 所有气泡 → 统一升级 | P1 | ✅ PASS | showUpdateBadgesOnAllCats + PersistentBadge 等价模式 11 tests |
| 7 | 无 brew → 浏览器打开 releases | P2 | ✅ PASS | brewPath()==nil → openReleasesPageInBrowser |
| 8 | 网络失败 → 静默重试 | P2 | ✅ PASS | catch 块 NSLog + 不写缓存时间戳 |
| 9 | 无活跃猫 → 新猫出现时显示气泡 | P2 | ✅ PASS | addCat 检查 updateAvailable != nil |
| 10 | API 格式异常 → 静默失败 | P2 | ✅ PASS | 三层 guard 验证 |

**场景计数**: N=10, E=10, E=N ✅

## Wave 2: 代码质量
- 新增: UpdateChecker.swift 202 行
- 修改: 8 文件 +181/-1 行
- TODO/FIXME: 0
