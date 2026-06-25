# gitSubdir source sha 改可选（消除 monorepo 更新 mismatch 死结）+ TOFU 严格首次（isEverTrusted 只看 name）

<!-- tags: pluginsourceconfig, gitgsubdir, sha, optional, decodeifpresent, monorepo, hot-reload, mismatch, tofu, isevertrusted, trust-model, first-use-only, homebrew-model, security-tradeoff, marketplace, sync, verifysha, giturl, trustkey -->

**Scenario**: 插件 source 配置 `gitSubdir(url, path, ref, sha)` 的 sha 原强制必填 + `verifySHA` 校验（`MarketplaceManifest.swift` + `PluginSourceResolver.swift`）。但 monorepo 持续更新（push 新 commit）→ 新 HEAD sha ≠ marketplace.json 旧 sha → verifySHA mismatch → 自动更新死结。另：TOFU 每次 exe 变弹框 = 更新反复打断。

**Lesson**:
- **gitSubdir sha 改可选（镜像 gitURL）**：`gitSubdir.sha: String` → `String?`（decode `decodeIfPresent` + encode `encodeIfPresent`）；`PluginSourceResolver` gitSubdir 分支 verifySHA 改 `if let sha { try verifySHA }`（镜像 gitURL 的可选 sha 模式，`:60-65`）。monorepo marketplace.json 的 gitSubdir source **不填 sha**（仅 `ref:"main"` 跟随最新）→ 消除 mismatch 死结，自动更新生效。安全：git clone HTTPS（GitHub 来源可信），与 gitURL 现有可选 sha 模式一致。
- **TOFU 严格首次**：`TrustStore.isEverTrusted(pluginName)` 只按 name 查记录（不看 exe hash）；`checkAndPrompt` 首行 `if isEverTrusted(plugin.name) { return true }`（已信任直接放行）。首次（无记录）弹 NSAlert，信任后写记录；后续更新（exe 变）免提示。sync 自动覆盖路径（`installPlugin`）不调 checkAndPrompt（本就如此）。
- **官方/第三方同 codepath**：`isEverTrusted` 签名仅 `pluginName`（无 source 参数）→ 官方与第三方插件更新行为不可区分（同一 codepath）。
- **安全取舍（用户已接受）**：首次信任某插件后，其作者后续更新静默生效。等价 Homebrew/apt「信任源后更新不再逐次确认」。trustKey 仍记录含 exe hash（审计/显示），但不用于「是否重新弹框」判定。

**How to apply**:
- git source 更新场景（monorepo/插件持续更新）：sha 改可选，不填 sha（ref 跟随最新），避免 mismatch 死结。强校验场景（固定版本/安全敏感）保留 sha。
- TOFU「信任源后免打扰」体验：isEverTrusted 只看 name，首次弹框后续免提示；与 sha 可选同属「信任后不再反复校验」哲学。
- 改 trust 判定逻辑时确认所有 checkAndPrompt 调用点（用户主动执行 vs sync 自动更新）行为一致。

**关联**: [[2026-05-27-tofu-trust-key-includes-exe-bytes]]（TOFU 原 exe hash 模型，本轮改为严格首次）、[[2026-05-29-swift-enum-polymorphic-json-codable]]（PluginSourceConfig Codable）、[[2026-06-25-build-time-fetch-gitignore-artifact-compiled-plugin-hotreload]]（同轮架构）。
