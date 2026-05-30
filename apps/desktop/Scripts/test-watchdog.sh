#!/usr/bin/env bash
#
# 测试看门狗：给 swift test 套一个墙钟上限，超时即判定挂死、终止进程并指出嫌疑测试。
#
# 背景：launcher 的 SwiftUI 永不终止动画（TimelineView(.animation)）曾在测试中残留窗口、
# 把 CFRunLoop 拖入空转，导致 swift test 偶发挂死数小时。根因已修（测试下冻结动画），
# 此脚本是「防御兵线」——任何未来再出现的 flaky 死锁都会在 ${TEST_TIMEOUT}s 内失败，
# 而不是把本地/CI 挂死几个小时。
#
# 用法：
#   bash Scripts/test-watchdog.sh [swift test 的参数...]
#   TEST_TIMEOUT=300 bash Scripts/test-watchdog.sh --filter Launcher
#
set -uo pipefail

TEST_TIMEOUT="${TEST_TIMEOUT:-600}"   # 默认 10 分钟（正常全量执行 ~125s，留足编译余量）
LOG="$(mktemp -t buddy-swift-test)"

# 后台启动 swift test，输出写入日志
swift test "$@" >"$LOG" 2>&1 &
TEST_PID=$!

# 实时把日志回显到终端
tail -n +1 -f "$LOG" 2>/dev/null &
TAIL_PID=$!

# 看门狗：每 5s 检查一次，超过上限则终止并报告
TIMED_OUT=0
(
  elapsed=0
  while kill -0 "$TEST_PID" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$TEST_TIMEOUT" ]; then
      {
        echo ""
        echo "⛔ 测试超过 ${TEST_TIMEOUT}s 未完成 → 判定挂死，正在终止。"
        echo "🔎 最后开始、但没有对应 passed/failed 的测试（疑似挂死点）："
        # 取最后一条 started；若它没有同名的 passed/failed，即为嫌疑
        last_started=$(grep "' started" "$LOG" | tail -1)
        echo "   ${last_started:-（无测试启动记录，可能卡在编译/链接）}"
        echo "💡 提示：用 sample <pid> 抓栈，或 TEST_TIMEOUT=N 调整上限。"
      } | tee -a "$LOG"
      pkill -f ClaudeCodeBuddyPackageTests 2>/dev/null
      kill "$TEST_PID" 2>/dev/null
      exit 0
    fi
  done
) &
WATCHDOG_PID=$!

wait "$TEST_PID"
STATUS=$?

# 清理看门狗与 tail
kill "$WATCHDOG_PID" 2>/dev/null
sleep 0.2          # 让 tail 冲刷完最后的输出
kill "$TAIL_PID" 2>/dev/null

# 被看门狗杀掉时 swift test 退出码非 0，但语义是「挂死」——已在上面打印说明
exit "$STATUS"
