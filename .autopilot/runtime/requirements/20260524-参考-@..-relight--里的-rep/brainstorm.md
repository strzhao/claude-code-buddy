## 探索的目的与约束

**用户目标**：参考 relight 的 monorepo 设计，把独立仓库 claude-code-buddy-web（Next.js + cli/ 子项目）整合进 claude-code-buddy 仓库；同时保留并组织好两套 CLI 工具（Swift 的 buddy 与 Node 的 buddy-skin）。

**项目现状关键发现**：
- claude-code-buddy 当前是纯 Swift 工程，`Package.swift`、`Sources/`、`Tests/`、`Makefile`、`release.yml` 都在仓库根目录，没有任何 Node/JS 痕迹。
- claude-code-buddy-web 是独立 Next.js 16 项目（@upstash/redis + @vercel/blob + pixi.js），内部还有 `cli/` 子工程（`buddy-skin` 命令，commander + archiver）。
- relight 用 pnpm workspace + `apps/{mac,web,backend}` + `packages/shared`，turbo 编排，Biome 替代 ESLint，所有内部依赖用 `workspace:*` 协议；`apps/mac` 与 web 并存，CI 通过 `--filter='!@relight/mac'` 排除 macOS 构建。
- 当前 Swift→Web 的唯一耦合点：`Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift` 硬编码 `https://buddy.stringzhao.life/api/skins`。

**约束**：
- Swift 工程的 `Package.swift path:` 字段、release.yml 中的 `.build/arm64-apple-macosx/release/...` 路径、Homebrew cask 等都对当前根目录结构敏感，迁移要一次性同步改完。
- Vercel 部署是用户手动触发，远端无 GitHub auto-deploy，所以 Vercel 项目 Root Directory 配置不需要在本次迁移内自动化。
- web 项目当前 npm，要切换到 pnpm。
- web 仓库已有 husky/commitlint/lint-staged/eslint/prettier/vitest/playwright/size-limit 全套工具链，搬迁时要合并到根级或保留在 apps/web 内。

## 候选方案与权衡

逐项澄清后已经形成单一推荐方案，不再发散三选一。下表对比的是用户决策选项，每个决策都已 Q&A 确认。

| 决策点 | 选项 | 用户确认 |
|---|---|---|
| Swift 工程位置 | apps/desktop vs 保留根 vs 不动文件 | **搬到 apps/desktop/** |
| Web 历史保留 | git subtree vs 复制 vs 双保险 | **直接复制，不带历史** |
| 包管理器 | pnpm vs npm workspaces vs yarn berry | **pnpm** |
| CLI 范围 | 只 skin-cli vs 还有别的 vs 重命名统一 | **两套都带进来（Swift BuddyCLI 跟 apps/desktop 走、Node skin-cli 进 packages/skin-cli/）** |
| Vercel 部署 | 远端切换 vs 暂不动 vs 立刻迁移 | **本地手动部署，远端不自动部署，迁移期间不动 Vercel 配置** |
| CI 策略 | 双 workflow + path filter vs 统一 turbo vs 只保留 Swift | **双 workflow + path filter** |
| npm scope | @cc-buddy/* vs @claude-code-buddy/* vs 不动 | **`@stringzhao/*`（@stringzhao/web, @stringzhao/skin-cli）** |

## 选择与理由

**最终方案：分层 monorepo（apps/desktop + apps/web + packages/skin-cli），pnpm workspace 管理 JS 部分，Swift 部分由 SPM/Makefile 维持原貌，CI 与 release 流水线按子目录路径过滤独立运行**。

理由：
- 一次性把 Swift 工程搬到 apps/desktop/，避免 monorepo 顶层目录被 Swift 工程"占座"，长期清爽（用户已确认）；release.yml 一次性改完 build 产物路径与工作目录即可。
- 直接复制 web 文件（不带历史）让主仓 git log 干净；老仓库需要时仍可独立访问。
- pnpm + `workspace:*` 对齐 relight，packages/skin-cli 用 workspace 协议即可被 apps/web 复用，避免 file: 路径硬编码。
- 双 CI workflow + path filter 比统一 turbo 学习成本低、迁移期间故障半径小；turbo 可作为后续优化项。
- `@stringzhao/*` scope 与现有 `@stringzhao/auth-sdk` 公开包共存无冲突（workspace 协议优先解析本地）。
- 不引入 turbo / biome / changesets 等额外工具——这些是 relight 的可选优化，引入会扩大本次范围、违反 YAGNI。

**被排除方案**：
- 双仓库 + submodule：用户明确要"整合进来"，submodule 不算整合。
- 一锅端用 turbo：在 Swift 不参与 turbo 任务图、CI 又要单跑的前提下，turbo 价值有限，是过早优化。
- 切到 Biome：web 项目已稳定运行 ESLint+Prettier，强切换会触发大量 diff 与潜在规则冲突，超出本次范围。

## 待主 SKILL 接力的设计决策

**已锁定决策（直接写进设计文档）**：

1. **目标目录拓扑**
   ```
   claude-code-buddy/                  (新根)
   ├── apps/
   │   ├── desktop/                    (= 原 root Swift 工程)
   │   │   ├── Package.swift
   │   │   ├── Sources/{App,BuddyCLI,ClaudeCodeBuddy}/
   │   │   ├── Tests/BuddyCoreTests/
   │   │   ├── tests/acceptance/
   │   │   ├── Scripts/
   │   │   └── Makefile
   │   └── web/                        (= 原 claude-code-buddy-web/ 顶层，剔除 cli/)
   │       ├── package.json            (name: @stringzhao/web)
   │       ├── src/  public/  e2e/  __tests__/  scripts/
   │       └── next.config.ts  middleware.ts  postcss.config.mjs  vitest.config.mts  playwright.config.ts  eslint.config.mjs  .prettierrc.json  tsconfig.json
   ├── packages/
   │   └── skin-cli/                   (= 原 claude-code-buddy-web/cli/)
   │       ├── package.json            (name: @stringzhao/skin-cli, bin: buddy-skin)
   │       └── src/ tsconfig.json
   ├── plugin/                         (保留在根：Claude Code marketplace 插件)
   ├── hooks/                          (保留在根：hook 脚本)
   ├── homebrew/Casks/                 (保留在根：Cask 配方)
   ├── docs/                           (保留在根)
   ├── .autopilot/                     (保留在根：跨项目知识)
   ├── .github/workflows/
   │   ├── ci-desktop.yml              (= 原 ci.yml，path: apps/desktop/**)
   │   ├── ci-web.yml                  (从 web 仓库迁入，path: apps/web/** + packages/**)
   │   └── release.yml                 (更新 build 产物路径)
   ├── .husky/                         (合并两仓的 hooks)
   ├── pnpm-workspace.yaml             (新建：apps/* + packages/*)
   ├── package.json                    (新建：name "claude-code-buddy"，private:true，packageManager: pnpm@X)
   ├── commitlint.config.cjs           (从 web 迁入根)
   ├── .lintstagedrc.json              (从 web 迁入根)
   ├── tsconfig.json                   (新建：base，apps/web tsconfig extends 之)
   ├── .gitignore                      (合并：原 Swift + node_modules/.next/dist/.turbo/.tsbuildinfo/.env*)
   ├── CLAUDE.md                       (重写：描述 monorepo 拓扑)
   └── README.md                       (统一)
   ```

2. **包命名**
   - `@stringzhao/web`（apps/web/package.json）
   - `@stringzhao/skin-cli`（packages/skin-cli/package.json，bin `buddy-skin` 不变）
   - apps/web 若需用到 skin-cli，写 `"@stringzhao/skin-cli": "workspace:*"`。

3. **包管理器**
   - pnpm。根 package.json 通过 `packageManager` 字段固定版本（参考 relight 用 pnpm@10.x）。
   - 删除 web/package-lock.json 与 web/cli/package-lock.json，由 pnpm-lock.yaml 接管。

4. **Swift 工程搬迁**
   - 整体 `git mv` 根目录下 Swift 相关文件/目录到 apps/desktop/：`Package.swift`、`Sources/`、`Tests/`、`tests/`、`Scripts/`、`Makefile`、`ClaudeCodeBuddy.app/`（如有）。
   - Package.swift 内部相对路径无需改（`path: "Sources/ClaudeCodeBuddy"` 等仍解析 apps/desktop/Sources/）。
   - Makefile 检查脚本路径是否依赖 PWD/相对路径；改成在 apps/desktop 下运行即可。
   - release.yml：所有 `swift build`、产物拷贝路径加 `working-directory: apps/desktop` 或 `cd apps/desktop &&`；其它 `.build/...` 路径同样前置 apps/desktop/。
   - ci.yml → ci-desktop.yml：同样加 working-directory。
   - Homebrew cask 不动（消费侧）。

5. **Web 项目搬迁（剔除历史，纯文件复制）**
   - 复制 `claude-code-buddy-web/` 除 `.git/`、`.next/`、`node_modules/`、`.vercel/`、`.env.local`、`tsconfig.tsbuildinfo`、`cli/` 之外的全部内容到 apps/web/。
   - `cli/` 单独复制到 packages/skin-cli/。
   - web 的 `package.json`：改 name 为 `@stringzhao/web`；保留所有 scripts、deps；删除 `prepare: husky`（移到根）。
   - cli 的 `package.json`：改 name 为 `@stringzhao/skin-cli`；保留 bin、scripts、deps。
   - 删除 web/.husky、web/.lintstagedrc.json、web/commitlint.config.js（统一到根）。

6. **根级工具链**
   - pnpm-workspace.yaml: `packages: ["apps/*", "packages/*"]`。
   - 根 package.json scripts：`"dev:web": "pnpm --filter @stringzhao/web dev"`、`"build:web": "pnpm --filter @stringzhao/web build"`、`"test:web": "pnpm --filter @stringzhao/web test"`、`"build:cli": "pnpm --filter @stringzhao/skin-cli build"`、`"build:desktop": "make -C apps/desktop build"` 等。
   - 根 tsconfig.json：base 配置（strict、ES2022）；apps/web/tsconfig.json `extends "../../tsconfig.json"`。
   - .gitignore 合并：Swift 原有 + node_modules、.next、dist、.turbo、.tsbuildinfo、.env*（保留 .env.example）、.vercel。

7. **CI 工作流**
   - `.github/workflows/ci-desktop.yml`：trigger `paths: ['apps/desktop/**', '.github/workflows/ci-desktop.yml']`；steps 沿用原 swift build/test/swiftlint，加 `working-directory: apps/desktop`。
   - `.github/workflows/ci-web.yml`：trigger `paths: ['apps/web/**', 'packages/**', 'pnpm-lock.yaml', '.github/workflows/ci-web.yml']`；setup pnpm + Node 20 → `pnpm install --frozen-lockfile` → `pnpm --filter @stringzhao/web lint typecheck test build size`。
   - `.github/workflows/release.yml`：trigger 不变（tag v*.*.*）；steps 加 working-directory apps/desktop；上传产物名不变。
   - 不引入 turbo / Biome / changesets。

8. **Vercel 部署**
   - 不在本次自动化中处理。用户后续手动在 Vercel UI 调整 Root Directory 为 apps/web 并改 Install/Build Command。在 README/CLAUDE.md 中记下"Vercel 部署：Root Directory 需手动改为 apps/web；Install Command: `cd ../.. && pnpm install --filter @stringzhao/web...`；Build Command: `pnpm --filter @stringzhao/web build`；Output Directory: apps/web/.next"。
   - apps/web/CLAUDE.md 保留 web 项目自身约定，根 CLAUDE.md 描述整体 monorepo。

9. **旧仓库后续**
   - 不在本次任务中归档；只在迁移完成后给出建议命令（用户手动决定）。
   - `Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift` 的 catalogURL `https://buddy.stringzhao.life/api/skins` 保持不变。

**验证关键点（供主 skill 写入验证方案）**：
- apps/desktop 内 `make build` + `make test` 通过（Swift 工程零回归）
- apps/desktop 内 `make bundle` 产出 .app，binary `buddy ping` 正常
- 根目录 `pnpm install` 成功，pnpm-lock.yaml 生成
- `pnpm --filter @stringzhao/web build` 产出 .next/ 无错
- `pnpm --filter @stringzhao/web test` + lint + typecheck 通过
- `pnpm --filter @stringzhao/skin-cli build` 产出 dist/index.js，`pnpm exec buddy-skin --help` 输出 commander 帮助
- pre-commit hook 在根仓库触发：lint-staged 对暂存的 .ts/.tsx/.swift 文件分别走 web/Swift 工具链
- GitHub Actions 模拟：本地 `act` 或 dry-run 验证 path filter 触发条件（或仅人工 review workflow YAML）
- catalogURL 不变，桌面端皮肤市场仍能拉到线上目录

**非目标（明确排除）**：
- 不切换 Biome（仍用 ESLint+Prettier）
- 不引入 turbo（用 pnpm -r / --filter 直接驱动）
- 不引入 changesets / 版本统一
- 不改 catalogURL，不动 Vercel 远端配置
- 不归档老 web 仓库（用户后续自行处理）
- 不引入 packages/shared 共享 types 包（若以后真的有共享需要再加）
