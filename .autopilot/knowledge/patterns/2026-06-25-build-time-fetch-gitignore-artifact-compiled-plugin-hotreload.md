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

**关联**: [[2026-06-19-coreimage-qr-universal-binary-marketplace-plugin]]（qr 编译型基础）、[[2026-05-26-spm-copy-executable-script-chmod-755]]（ensureStdinChmod 兜底）、[[2026-06-25-gitgsubdir-optional-sha-tofu-first-use-only]]（同轮 source/信任配置）。
