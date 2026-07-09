# 测试双路径 fallback（本地 clone 优先 + fetch 产物兜底）掩盖 CI workflow 缺 fetch-plugins step

> 2026-07-09 | CI Desktop #74 持续失败 34 测试修复（app commit 6fe76d2 / buddy-official-plugins 34933a1..71f6624）

适用场景：测试代码用「本地开发 clone 优先 + build-time fetch 产物 fallback」双路径定位资源（脚本/配置/快照），且项目有多个 GitHub Actions workflow（release 有 fetch、CI 没有）。凡是资源是 `.gitignore` 排除的 build-time 产物（fetch-plugins clone 填充）都适用。

## 陷阱 1：双路径 fallback 让本地永远绿、CI 永远红

**现象**：SnipScriptFunctionTests 本地全过，CI Desktop #74 上 11 个全挂（`("1") is not equal to ("0")` = 进程退出码 1）。

**根因**：测试的 `effectiveSnippetsSh` 双路径设计（SnipScriptFunctionTests.swift:47-51）：
```swift
if fm.fileExists(atPath: monorepoSnippetsSh.path) { return monorepoSnippetsSh }  // ~/workspace/buddy-official-plugins/...
return snippetsShPath  // Sources/.../Marketplace/plugins/snip/lib/snippets.sh
```
- **本地**：`~/workspace/buddy-official-plugins/` 存在（开发 clone）→ 走第一路径 → snippets.sh 存在 → 过
- **CI**：无本地 clone → fallback 到 fetch 产物路径 → 但 ci-desktop.yml 不跑 fetch → `Marketplace/plugins/snip/` 为空（.gitignore 排除）→ `source` 不存在的脚本 + `set -euo pipefail` → exit 1 → 所有 `XCTAssertEqual(exit, 0)` 挂

双路径本意是「本地开发免 fetch + CI 用 fetch 产物」，但 fallback 在本地静默成功，**掩盖了「CI 根本没 fetch」这个上层缺口**——典型 works-on-my-machine。单看本地测试永远发现不了。

## 陷阱 2：多 workflow step 不对称（release 有 fetch、CI 没有）

**现象**：同 SHA 98d5545，release.yml #52 build 成功，ci-desktop.yml #74 test 失败。看似矛盾。

**根因**：release.yml:35 有 `make -C apps/desktop fetch-plugins`（fetch 失败令 CI 失败，C1 契约「release 不带插件=残缺 app」），ci-desktop.yml 只有 `make build` + `swift test` + lint **无 fetch**。两个 workflow 的 setup step 不对称。`Marketplace/plugins/` 被 .gitignore 排除（build-time 产物），checkout 后只有 `.gitkeep` → 依赖该产物的测试全挂。

**「release 能过 = 代码没问题」是误判**：release 只 build 不 test，编译不检查 marketplace.json 内容、不 source 脚本；test 才暴露产物缺失。同 SHA 一个绿一个红，首要怀疑方向应是「两 workflow 跑的 step 不同」而非「代码在 CI 环境异常」。

## 陷阱 3：seed marketplace.json 漏随功能演进 + 数据源未推

**现象**：test_AT06 计数 3≠4（期望 hello/qr/qzh/snip）。

**根因（三重缺失叠加）**：cc274ce 引入 snip GUI + test_AT06（期望 4 插件），但三处都没跟上：
1. **seed marketplace.json 没加 snip**（git 里只 hello/qr/qzh）—— cc274ce 漏更新
2. **GitHub buddy-official-plugins/main 没 snip** —— 本地领先 3 commit 未 push（feat/chore/docs）
3. **ci-desktop.yml 不 fetch** —— 即使 monorepo 有也拉不进 bundle

fetch-plugins.sh 的 `generate_bundle_marketplace` 会从 monorepo marketplace.json 重新生成覆盖 seed，但 CI 没 fetch → 用 git seed（3 个）；即使 fetch，GitHub 当时也没 snip。三层全缺才让 test_AT06 挂——单修一层不够，必须 fetch 链路 + 数据源 + seed 三者都通。

## 方案（系统性，三层全修）

1. **CI workflow 对齐**：ci-desktop.yml 在 build 前加 `make fetch-plugins`，与 release.yml step 对称。**新增依赖 build-time 产物的能力时，所有跑 test 的 workflow 都要 fetch**（不是只 release）。
2. **数据源同步**：buddy-official-plugins 的插件源（plugin.json + 脚本 + marketplace.json 条目）必须 push 到 GitHub main，否则 fetch 从 GitHub clone 拉不到。本地 clone 领先 ≠ 已发布。
3. **seed 自洽**：seed marketplace.json 随功能演进同步更新（即使会被 fetch 覆盖，也要 baseline 自洽 + 作 fetch 失败兜底）。
4. **诊断测试不进回归 gate**：`record: .all` 这类「每次录制即失败」的人工诊断测试（SnipPanelRenderDiagnosticTests），用 `isCI`（`ProcessInfo.processInfo.environment["CI"] != nil`）环境跳过（对齐 SettingsPageSnapshotTests/CatSpriteSnapshotTests 惯例），本地保留诊断能力。

## 诊断手法（多组件系统逐层取证）

- **同 SHA 对比多 workflow 结论**（release vs ci-desktop）→ 「build 过 test 挂」= 产物缺失，非编译问题
- **`grep -c '"name":' marketplace.json` + `ls Marketplace/plugins/`** → 确认 fetch 产物/seed 是否就位
- **模拟 CI 路径**：`bash -c 'set -euo pipefail; . <fetch-产物路径>/snippets.sh; <函数调用>'` → 确认 fallback 路径（非本地 monorepo 路径）可用，绕过双路径 fallback 的本地掩盖
- **`git -C <monorepo> log origin/main..HEAD`** → 发现未推送 commit（数据源滞后于本地）
- **CI=true 跑诊断测试** → 确认 isCI 跳过生效

## 关联

- [[2026-06-25-build-time-fetch-gitignore-artifact-compiled-plugin-hotreload]]：build-time fetch 机制本体（gitignore 产物 + .gitkeep + Makefile 链式），本 pattern 是其 CI 集成缺口
- [[2026-04-18-release-bundle-script-desync-integrity-check]]：release.yml 与打包脚本不同步致产物缺资源，同「多 workflow/脚本 step 不对称」类
- [[2026-07-09-custom-nsview-autolayout-zero-size-testhook-blindspot]]：test hook 绕真实链路致全绿带 bug，同「测试机制掩盖真实缺口」家族（test hook 盲区 vs 双路径 fallback 盲区）
- [[2026-07-01-command-dual-path-ui-vs-ai-flow]]：command 双执行路径只堵 UI 层不够、AI 流仍坏，同「双路径只修一条」陷阱家族

---
<!-- tags: ci, github-actions, ci-desktop, release-yml, workflow-asymmetry, fetch-plugins, build-time-fetch, dual-path, fallback, masks-gap, works-on-my-machine, monorepo, buddy-official-plugins, seed-marketplace, gitignore-artifact, record-mode, diagnostic-test, isci, full-green-not-bug-free, snip, swift-test -->
