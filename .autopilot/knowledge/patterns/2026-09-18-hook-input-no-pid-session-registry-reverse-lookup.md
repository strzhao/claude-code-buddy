# Claude Code hook input 无 pid 字段——会话进程信息须经 `~/.claude/sessions/` 注册表反查 + argv 判型

<!-- tags: claude-code, hook, pid, session-registry, headless, argv, ps, reverse-lookup, verify-before-assume, plan-reviewer, autopilot -->
**Scenario**: app 侧需判定 hook 上报的会话是否 `claude -p` 无头模式（按进程 argv 判型），前提是拿到 claude 主进程 pid——设计时假设「hook input 带 pid」直接透传即可。
**Lesson**:
1. **Claude Code hook input 公共 schema 没有 `pid` 字段**（SDK 0.49.1 cli.js schema + 官方 hooks 文档双重确认：公共字段仅 session_id/transcript_path/cwd/permission_mode 等）。`d.get("pid")` 永远空——基于该假设的整条管线落地即空转，且**静默空转**（字段缺省不报错）。对外部系统输入 schema 的假设必须先实证（本例由 plan-reviewer 三重实证抓出）。
2. 正确 pid 来源 = CC 自带 session 注册表 `~/.claude/sessions/<pid>.json`：按 sessionId 反查得 pid+procStart；进程退出后文件同步消失，反查窗口恰覆盖「活着才需判型」；SessionStart hook 与文件落盘同秒级，仍需短重试（0.5s×4）+ 缺失 fail-open 兜底。
3. **注册表 `kind`/`entrypoint` 字段不可用作 headless 判型**（实证 10/10 个文件含 `claude -p --headless` 进程在内 `kind` 全为 `"interactive"`）；唯一可靠判型 = `ps -o args= -p <pid>` 输出按空白分词后含 `-p`/`--print` **精确 token**（非子串，防 `-printer` 误判）。
4. `ps` 判活三分支：ESRCH=进程死（可判 dead 立即清理）、EPERM=活（权限拒）、0=活；macOS pid 复用会令 kill(pid,0) 误报存活——用注册表 `procStart` 比对 `ps -o lstart=`（格式逐字同构）防御。
**Evidence**: autopilot 20260917-开始实现（猫上限去除与后台任务展示）：初版设计「app 拿 hook pid 检测」被 plan-reviewer BLOCKER-1 否决；改注册表反查后真机 E2E——真实 hermes `-p` worker 全链路生效（status `headless=yes`/colors.json 键/零 tab title 事件），app 日志 9+ 条 `session classified headless` 真实事件。
