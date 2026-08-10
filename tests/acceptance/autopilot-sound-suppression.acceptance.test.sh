#!/bin/bash
# autopilot-sound-suppression.acceptance.test.sh
#
# 红队验收测试：autopilot 声音抑制 + Stop 事件 idle/task_complete 映射
#
# 黑盒契约断言（不读实现细节）。测试代表设计意图，WILL NOT pass
# 直到蓝队合并实现 —— 这是预期的 TDD 红灯。
#
# 覆盖契约：
#   C1  给 buddy-hook.sh 喂 Stop + cwd 含 .autopilot/runtime/active.ptr
#       → 发到 socket 的 JSON event 字段 == "idle"
#   C1' (worktree 变体) cwd 含 .autopilot/runtime/sessions/<name>/active.ptr
#       → event == "idle"
#   C2  给 buddy-hook.sh 喂 Stop + cwd 不含 active.ptr
#       → event == "task_complete"
#   C3  notify.sh auto-chain / project-qa 调用的 osascript 命令不含 "sound name"
#   C4  notify.sh complete / project-complete / error / project-design-complete /
#       review-accept 调用的 osascript 命令含 "sound name"
#
# 测试技术：
#   - C1/C2：写一个 AF_UNIX SOCK_STREAM 临时 python server 捕获 buddy-hook.sh
#     发出的消息，解析 JSON 取 event 字段。mock osascript 让 terminal_id 探测
#     快速无副作用。BUDDY_SOCKET_PATH 指向临时 socket。
#   - C3/C4：PATH 前置临时 bin/osascript（记录每次调用的参数到一个文件，
#     每个 call 一行、内部换行折叠为空格便于 grep），跑 notify.sh <scene>，
#     检查记录里是否含 "sound name"。
#
# 红队红线：
#   - 强断言 [ ... ] / test，失败必挂测试；禁 warn/skip/try-catch 吞异常
#   - 不读 buddy-hook.sh / notify.sh 实现细节（基于契约，非基于实现）
#   - C3/C4 增加「osascript 必须被调用过」的 sanity 断言，避免空记录假绿

set -euo pipefail

# ---------- 路径定位 ----------

# buddy-hook.sh：从脚本目录向上探测 repo root，失败回退到已知绝对路径
detect_hook_path() {
    local d
    d="$(cd "$(dirname "$0")" && pwd)"
    while [ "$d" != "/" ]; do
        if [ -f "$d/plugin/scripts/buddy-hook.sh" ]; then
            echo "$d/plugin/scripts/buddy-hook.sh"
            return 0
        fi
        d="$(dirname "$d")"
    done
    echo "/Users/stringzhao/workspace/claude-code-buddy/plugin/scripts/buddy-hook.sh"
}

HOOK="${BUDDY_HOOK_PATH:-$(detect_hook_path)}"
NOTIFY="/Users/stringzhao/workspace/string-claude-code-plugin/plugins/autopilot/scripts/notify.sh"

# ---------- 计数 / 输出 ----------

PASS=0
FAIL=0
FAILMSGS=()

pass() {
    PASS=$((PASS + 1))
    echo "  ✓ PASS [$1]"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILMSGS+=("FAIL [$1]: $2")
    echo "  ✗ FAIL [$1]: $2" >&2
}

# ---------- 临时工作区 ----------

TMP_ROOT=""
cleanup() {
    if [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT:-}" ]; then
        rm -rf "$TMP_ROOT"
    fi
}
trap cleanup EXIT

new_tmp_root() {
    TMP_ROOT="$(mktemp -d /tmp/autopilot-sound-acc.XXXXXX)"
}

# ---------- python unix-socket 捕获 server ----------
# 收第一条连接、读完即关，解析每行 JSON 取 event 字段写入 out 文件。
# 若收不到消息则写 __NO_EVENT__ + raw 转储，便于排查。
write_socket_server() {
    cat > "$TMP_ROOT/sock_server.py" <<'PYEOF'
import socket, os, sys, json

socket_path = sys.argv[1]
out_file    = sys.argv[2]
timeout     = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0

if os.path.exists(socket_path):
    os.unlink(socket_path)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(socket_path)
srv.listen(1)
srv.settimeout(timeout)

events = []
raw = ""
try:
    conn, _ = srv.accept()
    conn.settimeout(timeout)
    data = b""
    while True:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
    conn.close()
    raw = data.decode("utf-8", errors="replace")
    # 逐行尝试解析（hook 可能发多行/单行 JSON）
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ev = obj.get("event") if isinstance(obj, dict) else None
        if ev is not None:
            events.append(str(ev))
    # 兜底：整段当一个 JSON 试一次
    if not events:
        try:
            obj = json.loads(raw.strip())
            ev = obj.get("event") if isinstance(obj, dict) else None
            if ev is not None:
                events.append(str(ev))
        except Exception:
            pass
finally:
    srv.close()
    try:
        os.unlink(socket_path)
    except OSError:
        pass

with open(out_file, "w") as f:
    if events:
        f.write("\n".join(events) + "\n")
    else:
        f.write("__NO_EVENT__\n__RAW_BEGIN__\n" + raw + "\n__RAW_END__\n")
PYEOF
}

# ---------- mock osascript ----------
# 每次调用把所有参数（换行折叠为空格）追加一行到 $OSASCRIPT_RECORD_FILE，
# 然后 exit 0，保证调用方流程不被打断。
write_mock_osascript() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/osascript" <<'EOF'
#!/bin/bash
args="$*"
printf '%s\n' "${args//$'\n'/ }" >> "$OSASCRIPT_RECORD_FILE"
exit 0
EOF
    chmod +x "$bin_dir/osascript"
}

# ---------- C1/C2：捕获 buddy-hook.sh 发出的 event ----------
# capture_hook_event <payload-json>
# 结果写入全局 CAPTURED_EVENT（取首行；无消息则为 __NO_EVENT__ 之类哨兵）。
CAPTURED_EVENT=""
CAPTURED_RAW=""

capture_hook_event() {
    local payload="$1"
    local sock="$TMP_ROOT/buddy.sock"
    local out="$TMP_ROOT/event.out"
    rm -f "$sock" "$out"

    python3 "$TMP_ROOT/sock_server.py" "$sock" "$out" 25 &
    local srv_pid=$!

    # 等 socket 起来（最多 ~5s）
    local waits=0
    while [ "$waits" -lt 100 ]; do
        if [ -S "$sock" ]; then
            break
        fi
        sleep 0.05
        waits=$((waits + 1))
    done

    local mock_bin="$TMP_ROOT/mockbin_hook"
    local osc_record="$TMP_ROOT/hook_osascript.log"
    rm -f "$osc_record"
    write_mock_osascript "$mock_bin"

    if [ ! -S "$sock" ]; then
        wait "$srv_pid" 2>/dev/null || true
        CAPTURED_EVENT="__SOCKET_NOT_UP__"
        CAPTURED_RAW=""
        return 0
    fi

    # 喂 stdin + env，hook 自行根据 payload.cwd 判定 active.ptr
    # 用 env 显式注入，避免污染当前 shell；hook 失败也不能让 set -e 中断套件
    printf '%s' "$payload" | \
        env BUDDY_SOCKET_PATH="$sock" \
            OSASCRIPT_RECORD_FILE="$osc_record" \
            PATH="$mock_bin:$PATH" \
            bash "$HOOK" >/dev/null 2>&1 || true

    # 等 server 落盘（消息已收到即写完退出）
    wait "$srv_pid" 2>/dev/null || true

    CAPTURED_EVENT="$(sed -n '1p' "$out" 2>/dev/null || true)"
    CAPTURED_RAW="$({ sed -n '2,$p' "$out" 2>/dev/null || true; })"
    [ -n "$CAPTURED_EVENT" ] || CAPTURED_EVENT="__NO_EVENT__"
}

assert_event_eq() {
    local expected="$1" label="$2"
    if [ "$CAPTURED_EVENT" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "expected event='$expected', got event='${CAPTURED_EVENT}' raw>>${CAPTURED_RAW}<<"
    fi
}

# ---------- C3/C4：notify.sh osascript sound name 探测 ----------
# run_notify_scene <scene>  →  全局 NOTIFY_RECORD 为本次所有 osascript 调用记录
NOTIFY_RECORD=""

run_notify_scene() {
    local scene="$1"
    local mock_bin="$TMP_ROOT/mockbin_notify"
    local record="$TMP_ROOT/notify_osascript.log"
    rm -f "$record"
    write_mock_osascript "$mock_bin"

    # notify.sh 失败也不中断套件（env 注入 mock bin 在 PATH 最前）
    env OSASCRIPT_RECORD_FILE="$record" \
        PATH="$mock_bin:$PATH" \
        HOME="${HOME:-/tmp}" \
        bash "$NOTIFY" "$scene" >/dev/null 2>&1 || true

    NOTIFY_RECORD="$(cat "$record" 2>/dev/null || true)"
}

assert_sound_present() {
    local scene="$1"
    if [ -z "$NOTIFY_RECORD" ]; then
        fail "C4:$scene" "osascript 未被调用（记录为空），无法断言 sound name"
        return 0
    fi
    if printf '%s' "$NOTIFY_RECORD" | grep -qF "sound name"; then
        pass "C4:$scene"
    else
        fail "C4:$scene" "osascript 调用未含 'sound name'，记录>>${NOTIFY_RECORD}<<"
    fi
}

assert_sound_absent() {
    local scene="$1"
    if [ -z "$NOTIFY_RECORD" ]; then
        fail "C3:$scene" "osascript 未被调用（记录为空），无法断言 sound name 缺席"
        return 0
    fi
    if printf '%s' "$NOTIFY_RECORD" | grep -qF "sound name"; then
        fail "C3:$scene" "osascript 调用不应含 'sound name'，记录>>${NOTIFY_RECORD}<<"
    else
        pass "C3:$scene"
    fi
}

# =====================================================================
# 测试用例
# =====================================================================

# C1：cwd 直接挂 .autopilot/runtime/active.ptr → event=idle
test_c1_active_ptr_idle() {
    local workdir="$TMP_ROOT/proj_active"
    mkdir -p "$workdir/.autopilot/runtime"
    touch "$workdir/.autopilot/runtime/active.ptr"

    local payload
    payload="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$workdir")"

    capture_hook_event "$payload"
    assert_event_eq "idle" "C1:active.ptr->idle"
}

# C1' (worktree 变体)：cwd 挂 .autopilot/runtime/sessions/<name>/active.ptr → event=idle
test_c1_worktree_variant() {
    local workdir="$TMP_ROOT/proj_worktree"
    local session="feature-sound-suppress"
    mkdir -p "$workdir/.autopilot/runtime/sessions/$session"
    touch "$workdir/.autopilot/runtime/sessions/$session/active.ptr"
    # 确保常规路径没有 active.ptr（证明 hook 认 sessions 变体）
    mkdir -p "$workdir/.autopilot/runtime"

    local payload
    payload="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$workdir")"

    capture_hook_event "$payload"
    assert_event_eq "idle" "C1:worktree-sessions-active.ptr->idle"
}

# C2：cwd 不挂 active.ptr（连 .autopilot/runtime 都建空）→ event=task_complete
test_c2_no_active_ptr_task_complete() {
    local workdir="$TMP_ROOT/proj_idle"
    mkdir -p "$workdir/.autopilot/runtime"
    # 故意不创建 active.ptr

    local payload
    payload="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$workdir")"

    capture_hook_event "$payload"
    assert_event_eq "task_complete" "C2:no-active.ptr->task_complete"
}

# C3：auto-chain / project-qa 不出声
test_c3_sound_suppressed_scenes() {
    local scene
    for scene in auto-chain project-qa; do
        run_notify_scene "$scene"
        assert_sound_absent "$scene"
    done
}

# C4：complete 家族出声
test_c4_sound_scenes() {
    local scene
    for scene in complete project-complete error project-design-complete review-accept; do
        run_notify_scene "$scene"
        assert_sound_present "$scene"
    done
}

# =====================================================================
# runner
# =====================================================================

main() {
    echo "=== autopilot sound suppression — 红队验收 ==="
    echo

    # 前置检查（缺依赖直接硬挂，区别于契约红灯）
    if [ ! -f "$HOOK" ]; then
        echo "ERROR: buddy-hook.sh 未找到：$HOOK" >&2
        exit 2
    fi
    if [ ! -f "$NOTIFY" ]; then
        echo "ERROR: notify.sh 未找到：$NOTIFY" >&2
        exit 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: 需要 python3（socket 捕获 server 依赖）" >&2
        exit 2
    fi

    new_tmp_root
    write_socket_server

    echo "[C1] Stop + active.ptr → idle"
    test_c1_active_ptr_idle
    echo

    echo "[C1'] Stop + sessions/<name>/active.ptr (worktree) → idle"
    test_c1_worktree_variant
    echo

    echo "[C2] Stop + 无 active.ptr → task_complete"
    test_c2_no_active_ptr_task_complete
    echo

    echo "[C3] auto-chain / project-qa → osascript 不含 sound name"
    test_c3_sound_suppressed_scenes
    echo

    echo "[C4] complete 家族 → osascript 含 sound name"
    test_c4_sound_scenes
    echo

    echo "==============================="
    echo "PASS: $PASS   FAIL: $FAIL"
    echo "==============================="
    if [ "$FAIL" -ne 0 ]; then
        echo
        echo "失败明细："
        local m
        for m in "${FAILMSGS[@]}"; do
            echo "  - $m"
        done
        exit 1
    fi
}

main "$@"
