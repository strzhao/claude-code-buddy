# Plugin 缓存与源码不同步导致 hook 事件映射错误

<!-- tags: plugin, cache, hooks, debugging, event-mapping -->
**Scenario**: 源码 `plugin/scripts/buddy-hook.sh` 中 `"Stop"` 已映射为 `"task_complete"`，但 `~/.claude/plugins/cache/claude-code-buddy/...` 中的缓存版本仍是旧的 `"idle"` 映射，导致猫咪在 Claude Code 停止时从不走到右边床上睡觉。
**Lesson**: Claude Code plugin 系统从 `~/.claude/plugins/cache/` 读取 hook 脚本执行，不会自动检测源码变更。修改 hook 脚本后必须手动同步到三个位置：(1) `plugin/scripts/buddy-hook.sh`（源码）(2) `hooks/buddy-hook.sh`（本地副本）(3) `~/.claude/plugins/cache/...`（运行时缓存）。当 hook 行为不符合预期时，首先 diff 缓存与源码版本。
**Evidence**: 用户报告 Stop 事件从未触发 taskComplete 状态，排查发现缓存脚本第 58 行 `"Stop": "idle"` 与源码 `"Stop": "task_complete"` 不一致
