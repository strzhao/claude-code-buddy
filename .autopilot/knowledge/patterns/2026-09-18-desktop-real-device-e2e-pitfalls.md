# 桌面 app 真机 E2E 验证驱动坑集合（LaunchServices 截胡 / 后台进程被清 / bash 全角括号吞变量）

<!-- tags: e2e, real-device, launchservices, open, bundle-id, nohup, background-process, bash, fullwidth-paren, unbound-variable, buddy-cli, qa, autopilot -->
**Scenario**: autopilot QA 真机 E2E：make bundle 后重启 app、跑 bash 验收清单脚本、buddy CLI 驱动。
**Lesson**:
1. **`open <新构建.app>` 会被 LaunchServices 按 bundle id 路由到 `/Applications` 已装旧版**——新功能全 404 造成成片假红（且极易误判为实现 bug）。重启后必须 `pgrep -fl` 验证运行路径；或直接 exec 二进制 `path/to/App.app/Contents/MacOS/App` 绕过路由。
2. **裸 `nohup ... &` 启动的 app 会随工具/会话清理静默消失**（无崩溃报告）——QA 期间 app 半路死亡导致后续断言全错。用受管后台任务（harness run_in_background）或 `open -a` 保持进程托管；断言前先 `buddy ping`。
3. **bash 里 `$VAR（`（多字节全角括号紧邻变量名）会把 0xEF 首字节吞进变量名 → unbound variable**，`set -u` 下脚本直接中止且报错名带乱码。中文文案的验收脚本高频踩：变量后接非 ASCII 字符一律写 `${VAR}`。同族：`grep -c` 多文件输出多行、`wc -l` 未 trim 直接进 `[ ]` 整数比较 → `integer expression expected`。
4. QA 驱动路径三件套先核对：① CLI 二进制新旧（Homebrew symlink 可能落后于 bundle 内嵌版）；② `BUDDY_LOG_LEVEL=debug` env 重启才能看到 debug 级链路日志（release 默认 info）；③ app 日志 `buddy log clear` 会归档当前文件——跨阶段 grep 证据要查归档 `buddy-*.jsonl`。
**Evidence**: autopilot 20260917-开始实现 QA：open 路由到 /Applications v0.40.2 造成 S2-P3/S5 系列成片假红（pgrep 实锤路径后改直接 exec 翻绿）；nohup 启动的 app 中途消失（无崩溃报告）；checklist 脚本 `$SEEN_HEADLESS（` unbound 中止（xxd 定位 0xEF 字节）+ `/usr/local/bin/buddy` 127（核对锚点：2026-09-18 QA artifacts）。
