# quota 插件

cc-switch 套餐限额查询（command mode 插件）。在 Launcher 输入 `quota` / `限额` / `套餐`，
即可看到 cc-switch 里 kimi 与智谱 GLM 各套餐的双窗用量（5h 滚动窗口 + 周窗口）
与距离额度重置的剩余时间。

## 用法

```bash
# Launcher 输入触发词后回车，或 CLI 直接 dry-run：
printf '{"query":"","sessionId":"qa","cwd":"/tmp"}' | ./quota.py
```

输出示例：

```
📶 cc-switch 套餐限额（3 个）

🟢 glm flash lastest（等 2 个条目）
　 5h 12% ↻3h20m ｜ 周窗 45% ↻2d2h

🟡 glm flash echo · 当前使用中
　 5h 62% ↻1h5m ｜ 周窗 75% ↻3d4h

🔴 kimi
　 5h 91% ↻40m ｜ 周窗 88% ↻5d
```

- 状态点按该条目双窗最大用量：≥85 🔴 / ≥60 🟡 / 其余 🟢（对齐 statusline-sage 阈值）
- `is_current` 的条目附「· 当前使用中」；同 token 的多条目合并为一行（附「等 N 个条目」）
- 触发词后带名称（如 `quota kimi`）按条目名子串过滤（大小写不敏感）
- 单条目失败/解析失败 → 该条目显示「⚠️ 暂时无法获取」，不影响其他条目

## 触发词

`quota` / `limit` / `限额` / `套餐` / `用量`

## 数据来源

- 本地：`~/.cc-switch/cc-switch.db`（SQLite，**read-only** 打开，不干扰 cc-switch 运行），
  取 `providers` 表 `app_type='claude'` 条目里的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
- 远端（仅支持的服务商）：
  - **kimi**（域名含 `kimi.com` / `moonshot`）：`GET {域名}/coding/v1/usages`，`Authorization: Bearer <token>`
  - **GLM**（域名含 `bigmodel` / `z.ai`）：`GET {域名}/api/monitor/usage/quota/limit`，`Authorization: <token>`（裸 token）
  - 其他服务商（deepseek / packy / 官方等）自动跳过，不发起任何请求
- 协议解析移植自 honeydo/gcli（kimi `duration==300+MINUTE` → 5h 窗、顶层 `usage` → 周窗；
  GLM `TOKENS_LIMIT|CREDIT_LIMIT` 按重置时间排序，首=5h 末=周窗）

## 依赖

零第三方依赖：`/usr/bin/python3`（macOS 自带 3.9）stdlib（sqlite3 / urllib / json）。
`deps: null`，`requiredPath: ["python3"]` 走框架预检（必过）。

## 隐私声明

- **令牌只用于查询额度接口的 Authorization 头**，不落盘、不进日志、不进输出
- 数据库只读打开，不写入、不修改任何 cc-switch 配置
- 请求经 HTTPS 直连服务商官方域名，无第三方中转

## 文件

- `quota.py` — 主脚本（command mode 可执行，shebang 绝对路径 `/usr/bin/python3`）
- `plugin.json` — 插件清单（mode=command，timeout 15s，内部 per-request 3s 自限）
- `tests/test_parsers.py` — 协议纯函数 unittest（49 用例，fixtures 为真实响应形状样例）
- `tests/fixtures/` — kimi / GLM 真实响应样例 + 畸形样例

## 契约要点

- **恒 exit 0**：所有失败（DB 缺失 / 非 JSON stdin / 请求失败）走 stdout 降级文案，绝不非零退出
- **输出**：纯文本 + emoji（无 ANSI 转义，plain text 渲染下同样可读），体量 < 4KB
- **stdout 容错**：stdin 空 / 非 JSON / tty 一律按空 query 处理（显示全部条目）
