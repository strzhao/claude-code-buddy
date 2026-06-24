# [2026-06-24] 日志系统：JSONL 落盘 + buddy log CLI（Foundation-only 直读）+ CLI·BuddyCore 路径 mirror 双绑

## 背景
app 无统一日志（~57 处 print/NSLog 散落各子系统），崩溃后无可追溯；需 debug/release 都写日志 + AI 便捷取阅。

## 决策
- **格式**：JSON Lines（`~/.buddy/logs/buddy.jsonl`），每行 `{ts,level,subsystem,msg,meta?}`，AI/jq 友好
- **落盘**：`BuddyLogger.shared` 单例（串行 `DispatchQueue` 保护 + 缓存 `FileHandle` append + `synchronize()` 崩溃前落盘）+ 5 MiB 轮转（归档 `buddy-<ts>.jsonl`）+ 50 MiB/30 个保留 + 容错静默降级（IO 失败绝不崩）
- **级别**：debug 构建默认 debug、release 默认 info、XCTest 宿主 off；`BUDDY_LOG_LEVEL` 覆盖；`BUDDY_LOG_DIR` 覆盖目录
- **CLI**：顶层 `buddy log {path|show|tail|grep|clear}`，**Foundation-only 直读文件**（app 不运行也能查，崩溃排查最关键），不走 socket
- **mirror 双绑**：CLI 不能 import BuddyCore（避免 AppKit/SpriteKit 拖慢启动），路径常量/级别集合/schema 字段名 mirror `LogConfig`（⚠️MIRROR 注释）；`BUDDY_LOG_DIR` 在 **app 侧也生效**（LogConfig.logsDir 优先读 env），否则测试隔离 app 写真实 home / CLI 读重定向目录 → CLI 读不到 app 日志

## 为什么
- JSONL > 纯文本：AI/jq 直接解析 + 结构化 meta；代价仅 tail -f 不直观（CLI show 摘要弥补）
- 直读文件 > socket 拉 app 内存：崩溃后排查场景 app 不运行，文件是唯一真相
- release 也写（info 级）：线上问题追溯，过滤 debug 噪音
- mirror 对称现有 `launcherConfigDir` 模式（CLI·BuddyCore 双绑陷阱）

## 反例（被否）
- socket 实时拉 app 内存日志：依赖 app 运行，崩溃后无法查
- 纯文本日志：AI 解析需正则，结构化字段易丢
- app 侧 buddyDir 只用 NSHomeDirectory() 不读 env：测试隔离下 CLI/app 目录分歧

## 影响
新增 `Sources/ClaudeCodeBuddy/Logging/{BuddyLogger,LogLevel,LogConfig,LogWriter}.swift` + `Sources/BuddyCLI/main.swift` log 命令组（+306 行）+ 收编 57 处 print/NSLog + clickLog 旁路。`apps/desktop/CLAUDE.md` 约定禁裸 print/NSLog。契约 C1-C6（文件/环境/API/CLI/mirror/标签）跨 app·CLI·文档稳定。关联 [[buddylogger-singleton-test-isolation-configurefortesting]]。

<!-- tags: logging, jsonl, buddy-log, cli, foundation-only, mirror, buddycore, rotation, fault-tolerance, singleton, serial-queue, synchronize, debug, release, bu-log-level, bu-log-dir, subsystem, contract, clicklog, app, socket, state-machine, session -->
