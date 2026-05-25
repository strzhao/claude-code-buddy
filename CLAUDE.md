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

## 子项目快速入口

- **桌面应用**: [apps/desktop/CLAUDE.md](apps/desktop/CLAUDE.md) — Swift 架构、状态机、调试猫、快照测试
- **Web 商店**: [apps/web/CLAUDE.md](apps/web/CLAUDE.md) — Next.js 架构、API 端点、认证系统
- **Skin CLI**: `packages/skin-cli/` — 皮肤包上传工具

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
