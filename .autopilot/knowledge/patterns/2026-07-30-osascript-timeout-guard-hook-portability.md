# osascript 阻塞时 timeout 守护行为 + hook 超时 best-effort 治理 + shell portability 降级

<!-- tags: osascript, timeout, hook, ghostty, portability, coreutils, best-effort, sigterm -->
**Scenario**: shell hook 脚本同步调 osascript（Apple Event）可能阻塞撞 hook 总超时被 cancel，需加 timeout 守护；且脚本发版给用户、不能假设运行环境时
**Lesson**:
1. osascript 阻塞时 SIGTERM 延迟生效，`timeout -k` 的 SIGKILL 也无改善——但裸 `timeout` 仍能在 hook 总超时内杀掉进程，故 `timeout` 足够、`-k` 非必要（不必为“SIGTERM 不响应”加 `-k` 保险，实测 `-k` 不更快）。
2. 发版给用户的 shell 脚本不能假设有 GNU coreutils（`timeout` 是 coreutils，macOS 默认不带）——用 `command -v timeout` 检测 + `gtimeout` 回退 + 裸跑降级；空变量前缀 `$($_VAR cmd)` 在 `$_VAR` 为空时展开为 `$(cmd)` 等价裸跑，是优雅降级的惯用法。
3. hook 超时治理：可选字段（如 terminal_id）用 best-effort 捕获 + 缺失降级，不阻塞主路径（socket 消息照发），把“捕获可能慢”隔离在可选副作用里。
**Evidence**: buddy-hook.sh 首事件 osascript 查 Ghostty 终端 ID 撞 2s hook 超时被 cancel（/doctor 扫 50 会话 17 次，所有 hook 里最多）；`timeout 0.5 osascript -e 'delay 5'` → exit 124, 1065ms（SIGTERM 后 ~565ms 才退出）；`timeout -k 0.2 0.5` → 1070ms（-k 无改善）；修复后首事件 591ms < 2s，socket 消息照发 + terminal_id 捕获（commit ea8ce13，plugin 1.0.0→1.0.1）（核对锚点：2026-07-30 源码版本）
