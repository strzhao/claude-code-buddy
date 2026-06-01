# 跨技术栈 monorepo 用 pnpm workspace + apps/* + packages/* 拓扑

<!-- tags: monorepo, pnpm-workspace, swift, nextjs, cli, architecture -->

**决策**: 把 macOS Swift 工程（apps/desktop）、Next.js Web（apps/web）、Node CLI（packages/skin-cli）统一在一个 git 仓库，用 pnpm workspace 管理 JS 部分，Swift 部分维持 SPM/Makefile，CI 用双 workflow + path filter 隔离。

**否决方案**:
- 单仓库 + turbo 统一 pipeline：Swift 不参与 turbo 任务图，turbo 价值有限，是过早优化
- 多仓库 + git submodule：用户明确要"整合"，submodule 不算
- 切到 Biome：web 项目稳定运行 ESLint+Prettier，强切引入大量 diff 超出范围

**理由**:
- 参考 relight 工程（apps/mac + apps/web + apps/backend）已验证 SwiftUI 与 Next.js 同仓共存可行
- pnpm `workspace:*` 协议 + `--filter` 直驱比 turbo 学习成本低、故障半径小
- 双 CI workflow（ci-desktop.yml + ci-web.yml）path filter 分别触发，避免 Swift 改动跑 web CI
- release.yml 加 `working-directory: apps/desktop`，并新增 `mv apps/desktop/*.zip ./` 步骤修复 softprops `files:` 路径（见 patterns）

**影响文件**: pnpm-workspace.yaml, package.json, tsconfig.json, .nvmrc, .github/workflows/{ci-desktop.yml,ci-web.yml,release.yml}, apps/desktop/, apps/web/, packages/skin-cli/

**约束**: 新增 JS/TS 子项目时放 packages/* 或 apps/*，命名用 `@stringzhao/*` scope + `private:true`；apps/web 不允许 `../../` 出边界，跨包依赖走 `workspace:*`；Swift 工程保持 SPM 内部相对路径（`path: "Sources/..."`），不引用 monorepo 根。
