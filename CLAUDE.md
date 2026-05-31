# Claude Code Buddy — Monorepo

macOS 桌面应用 + 皮肤包商店 Web 服务，统一在 pnpm workspace monorepo 中管理。

## Monorepo 拓扑

```
claude-code-buddy/
├── apps/
│   ├── desktop/          # macOS Swift 桌面应用（Dock 上的像素猫咪）
│   └── web/              # Next.js 皮肤包商店 Web 应用
├── packages/
│   └── skin-cli/         # 皮肤包上传 CLI 工具 (@stringzhao/skin-cli)
├── plugin/               # Claude Code hooks 插件
├── hooks/                # 本地 hook 脚本副本
├── homebrew/             # Homebrew cask 配方
├── docs/                 # 文档
└── .autopilot/           # autopilot 知识库（必须 git 提交）
```

## 常用命令

### Web 工程

```bash
pnpm --filter @stringzhao/web dev          # 启动开发服务器
pnpm --filter @stringzhao/web build        # 生产构建
pnpm --filter @stringzhao/web lint         # ESLint 检查
pnpm --filter @stringzhao/web test         # 单元测试 (Vitest)
pnpm --filter @stringzhao/web test:acceptance  # 验收测试
pnpm --filter @stringzhao/web test:e2e     # E2E 测试 (Playwright)
```

### Skin CLI

```bash
pnpm --filter @stringzhao/skin-cli build   # 编译 TypeScript
```

### Desktop 工程

```bash
make -C apps/desktop build       # 编译 debug
make -C apps/desktop test        # 单元测试
make -C apps/desktop lint        # SwiftLint 检查
make -C apps/desktop bundle      # 打包 .app
```

### 根级快捷脚本

```bash
pnpm build:web        # 等同于 pnpm --filter @stringzhao/web build
pnpm test:web         # 等同于 pnpm --filter @stringzhao/web test
pnpm build:cli        # 等同于 pnpm --filter @stringzhao/skin-cli build
pnpm build:desktop    # 等同于 make -C apps/desktop build
pnpm bundle:desktop   # 等同于 make -C apps/desktop bundle
```

### Launcher CLI

```bash
buddy launcher config set --provider anthropic --kind anthropic --model claude-sonnet-4-5 --api-key sk-xxx
buddy launcher config use anthropic
buddy launcher add <user>/<repo>       # 从 GitHub 装插件
buddy launcher list                     # 列出已装
buddy launcher inspect <name>           # 查看详情（JSON）
buddy launcher remove <name>            # 卸载
```

## 子项目快速入口

- **桌面应用**: [apps/desktop/CLAUDE.md](apps/desktop/CLAUDE.md) — Swift 架构、状态机、调试猫、快照测试
- **Web 商店**: [apps/web/CLAUDE.md](apps/web/CLAUDE.md) — Next.js 架构、API 端点、认证系统
- **Skin CLI**: `packages/skin-cli/` — 皮肤包上传工具
- **Launcher 启动器**: [apps/desktop/CLAUDE.md](apps/desktop/CLAUDE.md#launcher-子系统) — ⌘⇧Space 召唤 + AI 路由 + CLI 插件

## Agent Harness 设计

实现本工程的 agent（首要落地点：Launcher AI 路由 / 插件 agent）前，**必读** [docs/agent-harness-design.md](docs/agent-harness-design.md) —— 从兄弟仓库 `~/workspace/learn-everything/` 的 v1→v12 教学库与 `~/workspace/claude-code/` 工业源码综合的 harness 设计宪法。核心：

- **5 条元原则**：架构正交性（新子系统是加法非改造）、判决与执行分离、安全不依赖 model 自觉、runtime 强契约 vs prompt 软契约、cross-cutting 走单一入口。
- **12 个子系统**逐个拆解（loop / permission / mode matrix / fork / compaction / hook / observability / streaming / MCP / system-prompt / skill / TodoWrite），每条带 `file:line` 工业对照。
- **Launcher 现状对照**：已走完 v1 裸 loop + router，最大缺口是「dispatch 同权切面」未成型；推荐演进路线 P0（固化切面）→ P1（双层 permission）→ P2（plugin tool 同权化）。

> 遵循 learn-everything 的 **0 假设原则**：涉及具体函数/行号/调用链时先读源码再下结论，不凭命名推断。

## 开发环境要求

- **Node.js** >= 20（见 `.nvmrc`）
- **pnpm** 10.28.2（`corepack enable` 后自动激活）
- **Xcode** + Swift 5.9（desktop 工程）
- **SwiftLint**（`brew install swiftlint`）

## Hook 插件

`plugin/` 目录是 Claude Code plugin，通过 marketplace 安装。Hook 脚本 (`plugin/scripts/buddy-hook.sh`) 在每个 Claude Code 事件时通过 Unix socket 发送 JSON 消息到 app。

**注意**: 修改 hook 脚本后需要同步到三个位置:
1. `plugin/scripts/buddy-hook.sh` (源码)
2. `hooks/buddy-hook.sh` (本地副本)
3. `~/.claude/plugins/cache/...` (plugin 缓存，用户通过 marketplace 更新)

## Autopilot 知识库

`.autopilot/` 目录存储 autopilot 模式产生的知识沉淀，必须提交到 git：

```
.autopilot/
├── index.md          # 知识索引（decisions + patterns 摘要）
├── decisions.md      # 架构决策记录（ADR）
├── patterns.md       # 编码模式与经验教训
├── project/          # 项目设计文档与任务 DAG
└── requirements/     # 各需求的状态、设计、脑暴、QA 报告
```

## 任务管理

本项目的任务通过 ai-todo-cli 管理，任务空间为 `claude-code-buddy`（ID: `1f6cacb2-006f-4fc6-9126-bffb2e711743`）。

后续所有任务创建和进度更新都应同步到该任务空间：
- 创建任务时使用 `--parent_id 1f6cacb2-006f-4fc6-9126-bffb2e711743` 归属到此空间
- 完成工作后及时更新进度和日志
