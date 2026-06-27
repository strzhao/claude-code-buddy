# build-time fetch（编译时 git clone 资源打进 bundle，gitignored 产物）+ 编译型插件热更新失效（文件缺失非权限）

<!-- tags: build-time-fetch, monorepo, git, bundle, spm-copy, gitignore, gitkeep, fetch-plugins, makefile, chained-dependency, compiled-plugin, hot-reload, qr, universal-binary, ensurestdin-chmod, file-missing, plugin-crash, shell-vs-compiled, community-plugin, localsubdir, gitgsubdir, dual-track -->

**Scenario**: 资源（官方插件 hello/qr/qzh）需「源码在 git monorepo 单一真源 + bundle 离线可用 + 不依赖 app 发版热更新」。解法 = build-time fetch：Makefile `fetch-plugins` target 编译时 `git clone --depth 1` monorepo → rsync 填充 `Sources/.../Marketplace/plugins/`（整目录 gitignored + `.gitkeep` 占位）→ SPM `.copy("Marketplace")` 打进 bundle。运行时双轨：bundle `localSubdir`（离线 seed）+ 远程 `gitSubdir`（sync 更新）。

**Lesson**:
- **产物 gitignored + .gitkeep 占位**：app 仓库 `plugins/` 整目录 gitignored（fetch 产物），`.gitkeep` 占位让目录存在。SPM `.copy` 看文件系统（非 git），目录非空（fetch 后）即正常拷贝；空目录（fetch 前/失败）SPM 跳过但不崩（marketplace.json 仍在）。`fetch-plugins.sh` 缓存兜底（`.cache/buddy-plugins/`，clone 失败用缓存 exit 0）。
- **Makefile 链式依赖强制时序**：`fetch-plugins → build-qr-gen → fix-plugin-perms → build/bundle`。**Make 同行多 prerequisite 顺序不保证**（make 4.x 才 `.NOTPARALLEL`），改链式（`A: B`）强制时序，否则 fetch 没先跑 `qr-gen.swift` 不存在 → build-qr-gen 失败。release target 改依赖但**保留编译参数**（`--arch arm64` + `--target buddy-cli` 两次），否则 bundle 缺 buddy CLI。
- **编译型插件热更新失效（关键教训）**：qr 是 Swift（`qr-gen.swift` → universal binary，CoreImage 零依赖）。源码在 monorepo，binary 不入库（`.gitignore` 排除）。app build-time fetch 拉源码 + Makefile build-qr-gen 编译进 bundle。但**用户侧 release app 热更新**（`syncFromRemote` gitSubdir git clone monorepo）只拉源码，**无编译环境**（release 无 Makefile/swiftc）→ qr-gen binary 缺失 → `cmd ./qr-gen` 找不到 → `LauncherError.pluginCrash`。
- **问题不是权限，是文件缺失**：`ensureStdinChmod`（`MarketplaceManager.installPlugin` 后）已对 cmd 文件 chmod 0o755，但 `if fileExists(exePath)` 为 false（binary 缺失）时跳过。所以只要 binary 出现在拷贝源，整条链路自动闭环（git index `100755` + clone 还原 +x + `ensureStdinChmod` 兜底双保险）。
- **编译型 vs 脚本型**：shell 插件（hello/qzh）源码入库即可执行（热更新拉源码即用）；编译型（qr）需 binary 分发（入库预编译 universal / release asset / 运行时编译）。**社区插件框架应默认脚本型**（开发者门槛低、源码即分发、热更新零成本），编译型是例外。

**How to apply**:
- 资源 git 化（插件/皮肤/配置）：build-time fetch 模式（git clone + rsync gitignored 产物 + .gitkeep + SPM .copy + 缓存兜底 + 双轨 source）。
- Makefile 资源准备用链式依赖（不靠同行 prerequisite 顺序）；release/bundle 改依赖时保留编译参数。
- 编译型插件：优先 shell 化（社区友好）；若需编译（零依赖能力如 CoreImage），binary 入库 monorepo（git index `100755`，`.gitattributes` 标记 binary）或 release asset；`ensureStdinChmod` 已兜底 +x。
- QA 真机验收编译型插件热更新：模拟用户侧（`rm launcher-plugins/<name>` + sync gitSubdir clone）验证 binary 就位 + 可执行。

## ✅ 已落地（2026-06-28，社区插件优先闭环）

本文档预测的迁移全部兑现：
- **qr-gen.swift + universal binary 删除** → `qr-gen.sh`（command mode，`INPUT=$(cat)`+`jq` 取 query → `qrencode -s 24 -m 2 -l M` 写 `$BUDDY_OUTPUT_IMAGE`）。**-s 24 实测 600px ≥480px 可扫**（plan-reviewer 实测 `-s 10` 仅 250px 不可扫——模块放大参数必须按 `(模块数+2×margin)×-s ≥480` 算，不能拍脑袋）。
- **方案3 依赖机制首个真实用例**：`plugin.json deps:[{check:qrencode,brew:qrencode},{check:jq,brew:jq}]`，首次执行经 TrustPrompt「信任+依赖合并」弹框 + `installAllSync` 自动 `brew install`。
- **G1 根因+修复**：`release.yml` 直接 `swift build` 绕过 Makefile `fetch-plugins` 链 → 发版 `Marketplace/plugins/` 空（brew 用户拿不到官方插件 = 上次 qr 失踪根因）。修复 = release.yml `Build arm64` 前加 `make -C apps/desktop fetch-plugins`。**属 [[2026-04-18-release-bundle-script-desync-integrity-check]] 同类陷阱**（两条独立打包路径必须同步）的新实例（build-time-fetch）。
- **本地开发循环**：Makefile `fetch-plugins-local`（`BUDDY_OFFICIAL_PLUGINS_URL=file://` 指本地 clone），改 monorepo → `make fetch-plugins-local && make build` 即见效，免 push。
- 端到端真机验证：file:// fetch（sha 逐字一致）→ dev bundle → reseed → `buddy launcher run qr` exit 0（app log `launcher run ok`，538ms/18ms 两次）。

**关联**: [[2026-06-19-coreimage-qr-universal-binary-marketplace-plugin]]（qr 编译型基础）、[[2026-05-26-spm-copy-executable-script-chmod-755]]（ensureStdinChmod 兜底）、[[2026-06-25-gitgsubdir-optional-sha-tofu-first-use-only]]（同轮 source/信任配置）、[[2026-06-28-red-team-assertion-mechanism-precision]]（本次 SC1/SC7 红队断言误报教训）。
