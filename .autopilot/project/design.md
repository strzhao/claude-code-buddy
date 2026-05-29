# Buddy Plugin Market — 官方插件市场 + Buddy Store UI + Marketplace 协议

> 把现有"内置插件 + CLI git clone 安装"双轨模型重构为统一 Marketplace 协议（参考 [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official)）。translate 不再是"builtin"而是 marketplace "默认预装"条目；Settings → Buddy Store 加 [皮肤/插件] tab；官方 marketplace 走 GitHub Raw JSON；用户编辑能力推迟到 phase 2。

## Context

完整设计：见对应需求 state.md 的 `## 设计文档` 区域：
`.autopilot/runtime/sessions/translate/requirements/20260529-新增-market-的概念-1.-做/state.md`

**核心 UX 决策**（与用户对齐 + plan-reviewer 第 2 轮 PASS）：

- Settings 重命名 "Buddy Store" + 顶部 NSSegmentedControl 切 [皮肤/插件]
- 官方 marketplace = GitHub Raw JSON（零运营、PR 入口清晰、不依赖 Vercel）
- Plugin source 多态支持 4 种：`local-subdir` / `git-subdir` / `git-url` / `file`
- "内置"概念消失：bundle 内带种子 marketplace.json + plugins/ 作离线 fallback；后台从 GitHub Raw 同步
- Phase 1 **不做** prompt/触发词编辑（YAGNI），marketplace schema 预留 `editable: bool`
- 仅可"禁用"（`.disabled` 标记），不做真"卸载"
- 远程更新静默生效，**自建 in-app HUD**（替代 deprecated NSUserNotificationCenter）+ 状态栏提示

## 整体架构

### 数据流

```
App 启动
  ↓
1. MarketplaceManager.migrateLegacy()         ← 老用户 builtin-translate → translate 两阶段迁移（幂等）
  ↓
2. MarketplaceManager.seedFromBundle()        ← 首启或 ~/.buddy/marketplace.json 缺失时
     从 BuddyCore.bundle/Marketplace/marketplace.json 拷到 ~/.buddy/marketplace.json
     遍历 plugins[]，按 source 类型用 PluginSourceResolver 解析 → 拷到 ~/.buddy/launcher-plugins/<name>/
  ↓
3. PluginManager.list()                       ← 现有调用方
     扫 ~/.buddy/launcher-plugins/，跳过含 .disabled 的目录
  ↓
4. Task.detached: MarketplaceManager.syncFromRemote()   ← 异步后台（1h debounce）
     GET https://raw.githubusercontent.com/stringzhao/claude-code-buddy/main/marketplace/marketplace.json
     检测 schemaVersion 兼容；JSONDecoder 失败时本地 cache 不写
     diff plugins[] → 新插件/版本升级/移除 → 应用变更（保留 .disabled 标记）
     diff 非空 → MarketHUD.show("translate 已更新到 v0.2.0", actions:[查看diff, 重置])
     每次执行追加结构化日志到 ~/.buddy/launcher-sync.log
```

### 模块拓扑

```
Sources/ClaudeCodeBuddy/
├── Launcher/
│   ├── Marketplace/                          ← 新增目录
│   │   ├── MarketplaceManifest.swift         (Codable schema + PluginSourceConfig enum)
│   │   ├── PluginSourceResolver.swift        (4 类 source 解析: local-subdir/git-subdir/git-url/file)
│   │   ├── MarketplaceManager.swift          (seed/sync/install/migrateLegacy/reseed/inspect)
│   │   └── MarketHUD.swift                   (in-app NSPanel toast 替代 NSUserNotificationCenter)
│   ├── Plugin/
│   │   ├── PluginManager.swift               (改造：list() 加 .disabled 过滤，删 installBundledPlugins)
│   │   └── ... (其他保留)
│   └── ...
├── Settings/
│   ├── SettingsWindowController.swift        (改造：title → Buddy Store，加 segmentedControl)
│   ├── PluginGalleryViewController.swift     ← 新增（四态: normal/loading/empty/error）
│   └── SkinGalleryViewController.swift       (保留不动)
└── Marketplace/                              ← 新增 bundle 资源根
    ├── marketplace.json                      (seed，含 translate + hello)
    └── plugins/
        ├── translate/plugin.json             (从原 TranslatePlugin/ 迁移，name 改 "translate")
        └── hello/plugin.json                 (从原 HelloPlugin/ 迁移，name 改 "hello")
```

## 任务 DAG 概览

7 个任务，分两段：

```
001 ──→ 002 ──→ 003 ──→ 004 ──┬→ 005 (Buddy Store UI)
                              ├→ 006 (后台同步 + MarketHUD)
                              └→ 007 (CLI install/disable/enable/reseed)
```

- 001-004 串行：核心数据层 + 协议
- 005/006/007 并行：UI + 同步 + CLI 三独立子系统

详见 `dag.yaml`。

## 跨任务设计约束（执行铁律）

1. **PluginManager 协议不破坏**：list/find/pluginDir 接口保留，上游零改动
2. **TrustStore 兼容**：prompt-mode trustKey 仅依赖 systemPrompt/maxIter/model，**不依赖 pluginName**
3. **plugin.json `name` 字段同步迁移**：`builtin-translate` → `translate`，`builtin-hello` → `hello`
4. **`migrateLegacy()` 两阶段迁移**（crash safe）：先写新（目录 + trust），再删旧；幂等
5. **离线兜底**：seedFromBundle 必须无网可跑（CI 验证）
6. **后台同步失败不阻塞**：JSONDecoder 失败本地 cache 不写；连续 3 次失败 HUD 提示
7. **003/004 改 PluginManager.swift 必须串行**
8. **手动恢复**：CLI `buddy launcher reseed` 强制重新 seed（保留 .disabled）
9. **marketplace.json `schemaVersion: 1`**：phase 2 演进基础

## Handoff 策略

每个 task 完成后产出 `tasks/NNN-*.handoff.md`（≤500 字）：实现摘要 + 文件变更 + 下游须知 + 偏差说明。

## 验证方案（项目级集成 QA）

8 个 Tier 1.5 场景，6 个 CLI 自动化 + 2 个 GUI（详见 state.md `## 验证方案`）。

每个 task 自己的 Tier 1.5 在 brief 内定义；项目级集成 QA 在所有 task done 后执行。
