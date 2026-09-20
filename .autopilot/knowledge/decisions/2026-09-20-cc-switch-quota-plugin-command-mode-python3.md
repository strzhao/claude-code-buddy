# cc-switch 套餐 limit 插件：command mode + python3 stdlib 单文件 + SQLite ro 数据源

<!-- tags: launcher, community-plugin, quota, cc-switch, command-mode, python3, stdlib-only, sqlite-readonly, token-safety, gcli-protocol, dedupe, marketplace, plugins -->

**Scenario**: 需要在 buddy Launcher 快捷查看 cc-switch 下各套餐（kimi/GLM coding plan）的 5h/周窗用量与重置时间。cc-switch 各家套餐没有统一 limit 端点；协议知识散落在 honeydo gcli（cli.ts:548-820，已踩坑验证：kimi 数值是字符串、GLM nextResetTime 是 epoch-ms 数字、Bearer 前缀差异）。

**Choice**:
- **社区插件 `plugins/quota/`（command mode）**：确定性子进程产物零 LLM，与 qr/qzh 同类；不进 app（社区优先约定）。
- **python3 stdlib 单文件（/usr/bin/python3 绝对路径 shebang）**：macOS 自带 3.9.6，stdlib 有 sqlite3+urllib+unittest——零 brew dep、token 不经子进程参数（无 `ps` 暴露面）。否决 bash+jq+curl（token 经 ps + 解析边界重写易错）与 gcli 加子命令（跨仓 + 绑定 ROADMAP 计划废弃的 bin）。
- **数据源 = `~/.cc-switch/cc-switch.db`（SQLite read-only URI `?mode=ro`）**：`providers` 表 `app_type='claude'` 条目，`settings_config` JSON 含 `env.ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN`，`is_current` 标当前生效；域名分类（kimi.com|moonshot→kimi，bigmodel|z.ai→glm），端点 kimi `GET /coding/v1/usages`（Bearer 前缀）/ GLM `GET /api/monitor/usage/quota/limit`（裸 token）。
- **(kind, token) 去重**：cc-switch 同一账号常配多个条目（本机 glm 三条目两 token），按 (kind,token) 合并避免重复请求与重复行。
- **恒 exit 0 纪律**：StdinExecutor exit≠0 → pluginCrash 卡片（stderr 前 200 字，不可控）；所有降级（DB 缺失/锁住/损坏、请求失败、畸形 stdin）走 stdout 友好文案 + exit 0。
- **插件 manifest 全字段写齐**：keywords 曾因 required 缺失致 Codable 整体 decode 失败（[[2026-06-24-plugin-summary-displaysummary-mirror-cli-buddycore]]），新插件 name/version/summary/description/keywords/mode/cmd/args/env/timeout/requiredPath/deps/icon 全显式。
- **测试双保险**：49 个 unittest（协议纯函数移植 + 畸形样例）+ 红队 shell 验收（8 项，mutation 双向验证测试自身断言力）；artifact 纪律见 [[2026-08-10-stop-hook-predicate-artifact-backtick-dup]]（反引号包裹路径与多谓词同内容两个坑本轮全部实战踩中）。

**Alternatives rejected**:
- Claude 官方 Pro/Max 套餐：需 Keychain OAuth token + /v1/oauth/usage 协议，用户明确排除（首版只做 kimi+GLM）。
- stdin mode（stdout 回灌 LLM）：quota 查询是确定性展示，过 LLM 纯浪费。
- 60s 结果缓存：唤起频率低 + ≤4 并发请求 3s 超时上界，YAGNI。

**Trade-offs**: 直接读 cc-switch SQLite 私有库 = 与 cc-switch schema 耦合（其升级改表会静默失效——降级路径兜底「数据库暂时读不了」）；python 插件与本仓 bash 插件主流风格不一（hello.sh 已有 python3 先例，且零依赖收益大于风格一致性）。

**关联**: [[2026-06-25-build-time-fetch-gitignore-artifact-compiled-plugin-hotreload]]（脚本型社区插件默认形态）、[[2026-08-29-unified-candidate-mix-single-list-unified-score]]（keywords 触发统一打分）、[[2026-06-24-plugin-summary-displaysummary-mirror-cli-buddycore]]（manifest 向后兼容教训）。
