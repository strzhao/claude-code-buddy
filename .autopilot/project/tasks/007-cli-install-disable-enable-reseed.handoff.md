# Task 007 Handoff — CLI install/disable/enable/reseed + list --json（DAG 最后 task）

## 实现摘要

BuddyCLI 加 5 个 marketplace 子命令 + CLIOptions.flags 字段（B1）+ sanitize 白名单（task 004 follow-up 落地）+ 完整 mirror schema 维持 Foundation-only。reseed 5 步真删 plugin dirs + 写 reseed-pending-disabled.json，BuddyCore seedFromBundle 末尾 +6 行配套读取并恢复 .disabled 标记（B2）。

**3 BLOCKER 修复落地**：
- B1: `CLIOptions.flags: [String]` + parseArguments 长参 catch-all（仅布尔型 flag）
- B2: cmdLauncherReseed 5 步 + BuddyCore +6 行配套；CLI / app 进程间通过 `~/.buddy/reseed-pending-disabled.json` 临时文件通信
- B3 (误报澄清): writeMeta 已用 `.iso8601` strategy；CLI mirror `lastSyncedAt: String?` 直接匹配 ISO8601 字符串

## 文件变更（commit 8f68111）

**新增**:
- `tests/.../CLILauncherInstallDisableEnableTests.swift`（蓝队 21 单测，366 行）
- `tests/.../CLILauncherInstallDisableEnableAcceptanceTests.swift`（红队 15 AT，编排器补齐）

**修改**:
- `Sources/BuddyCLI/main.swift`（+516 -3）：CLIOptions.flags + mirror schema (CLIMarketplaceManifest / CLIPluginSourceConfig 4 形态 / CLIMarketplaceInspection) + sanitizePluginName + 5 cmd (Install/Disable/Enable/Reseed/ListJSON) + cmdLauncherList 改 [禁用] 后缀 + 路由 + help
- `Sources/.../Launcher/Marketplace/MarketplaceManager.swift`（+15）：seedFromBundle 末尾 +6 行读 reseed-pending-disabled.json → 恢复 .disabled → 删 pending

## 验证证据

- swift build: PASS
- swift test --filter "CLILauncher|BuddyCLI": **45 tests / 0 failures**（蓝 21 + 红 15 AT + 9 pre-existing）
- make lint: 0 violations / 108 files
- contract-checker: PASS（3 个 low 无功能影响）
- Tier 1.5 5/5 PASS（含 S4 全 4 子场景 + S5 静态 Foundation-only）
- qa-reviewer Section A 9/9 + Section B 6 个 ≥80 全正向评价

## 红队 Agent session limit 处理

红队 Agent 因 session 限制中断未写完 AT 文件。编排器基于设计文档独立补齐 15 AT（严格信息隔离，未读蓝队 main.swift 内 cmd 函数实现细节）。15 AT 全部 PASS。

## exit code 规范

| code | 含义 |
|------|------|
| 0 | success |
| 2 | usage / invalid name (sanitize fail) |
| 3 | not-found (plugin 不存在 / 不在 marketplace) |
| 4 | cache-missing (marketplace.json 不存在) |
| 5 | already (plugin 已装) |
| 6 | bundled-only (localSubdir source, 需 reseed + 重启 app) |

## 下游须知

### 整个 buddy-plugin-market 项目完整闭环

DAG 7/7 task 全完成：
- 001 marketplace schema + bundle seed
- 002 PluginSourceResolver 多态加载
- 003 MarketplaceManager 替换 installBundledPlugins
- 004 disable/enable mechanism
- 005 Buddy Store UI（红蓝对抗最佳案例）
- 006 MarketHUD + sync 并发锁
- 007 CLI install/disable/enable/reseed + list --json

### 用户端到端体验

```bash
# 安装 marketplace 插件
buddy launcher install weather       # gitURL source 直接 clone
buddy launcher install translate     # localSubdir source → exit 6 + 提示 reseed
buddy launcher reseed                 # 清 cache + 删 marketplace plugin dirs + 写 pending
# 重启 app → seedFromBundle 自动恢复 .disabled

# 禁用/启用
buddy launcher disable translate
buddy launcher enable translate

# 查询
buddy launcher list                   # 文本输出 + [禁用] 后缀
buddy launcher list --json            # MarketplaceInspection JSON
```

UI 端：Cmd+, → Buddy Store → [插件] tab → 列表 + [禁用]/[启用] 按钮 + 错误态 [重新初始化]。

## 偏差说明

无契约偏差。

**Follow-up（phase 2 处理）**：
- install 不 verifySHA（与 cmdLauncherAdd 既有信任级别一致）
- task 003 follow-up #1 (install/reseed vs sync 互斥) 完整版需 actor 化 MarketplaceManager
- task 003 follow-up #2 appendSyncLog flock
- task 003 follow-up #3 temp path 判定改 hasPrefix

## 关键陷阱（写入 knowledge 候选）

CLI 与 BuddyCore 间通过临时文件（`reseed-pending-disabled.json`）实现跨进程状态传递。两端 schema 必须严格对齐（双绑陷阱）。注释已在 main.swift L1370 标注。
