# 验收 e2e 三假源：陈旧 bundle 存在性检查 / buddy run --input 双契约 / bash 全角紧邻变量（再次实战）

<!-- tags: e2e, stale-bundle, buddy-cli, input-contract, bash-fullwidth, qa, false-red, acceptance-script -->

**Lesson**（autopilot 20260921 QA 轮一次踩全三个）:
1. **「构建产物在场」≠ 新鲜**：e2e 脚本 build 检查只验 `.app` 存在 → Sep 18 陈旧 bundle 被当新构建启动，旧代码+新插件组合出难解假象。修法：启动前 `make bundle` 重打 + `ls -la` 验主二进制 mtime。
2. **`buddy launcher run --input` 是裸 query**（瘦输出 dry-run 语义）；`--input '{"query":"x"}'` 的 JSON 提取契约属 `buddy run`/tools hub（C-INPUT-CONTRACT）。混用 → 整个 JSON 串被当插件 filter 词 → 报「没有名称匹配「{"query":"gc"}」」——**错误信息里带原始 JSON 恰是诊断线索**。
3. **bash 全角字符紧邻 `$VAR` 第三次实战**（本轮 `$S4P1）` 与 `$S3P4，` 两处）：全角首字节被吞进变量名 → `set -u` 下 unbound 崩、无 `set -u` 则静默。防法一律 `${VAR}`。

**How to apply**: 验收脚本里 `$VAR` 后接任何非 ASCII 字符（`）），。：` 等）强制写 `${VAR}`；e2e 硬断言「构建产物」必须含新鲜度验证；CLI 冒烟前先分清 `buddy launcher run`（裸 query）vs `buddy run`（JSON 提取）双通道契约。

**关联**: [[2026-09-18-desktop-real-device-e2e-pitfalls]]（全角坑首例 + LaunchServices 旧版路由假红）、[[2026-07-16-tofu-modal-sendquery-timeout-split-connect-execute]]（CLI 双通道契约分化先例）。
