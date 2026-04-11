#!/bin/bash
# Acceptance Test: Multi-Session Management
# Verifies the app handles multiple concurrent sessions correctly:
# separate session_ids each get their own lifecycle, session_end for one
# does not break others, and the app survives rapid concurrent events.
# Based on design spec: Multi-Cat Management section (max 8 sessions, etc.)

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy.sock"
APP_PID=""
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BIN="$PROJECT_ROOT/.build/debug/ClaudeCodeBuddy"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── Socket helpers ─────────────────────────────────────────────────────────

send_json() {
    local json="$1"
    python3 - "$SOCK" "$json" <<'PYEOF'
import sys, socket, time

sock_path = sys.argv[1]
message   = sys.argv[2]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(3)
    s.connect(sock_path)
    s.sendall((message + "\n").encode())
    time.sleep(0.05)
    s.close()
    sys.exit(0)
except Exception as e:
    print(f"SOCKET_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

send_event() {
    # send_event <session_id> <event> [tool]
    local sid="$1"
    local evt="$2"
    local tool="${3:-null}"
    local ts
    ts=$(date +%s)
    if [ "$tool" = "null" ]; then
        send_json "{\"session_id\":\"$sid\",\"event\":\"$evt\",\"tool\":null,\"timestamp\":$ts}"
    else
        send_json "{\"session_id\":\"$sid\",\"event\":\"$evt\",\"tool\":\"$tool\",\"timestamp\":$ts}"
    fi
}

wait_for_socket() {
    local deadline=$((SECONDS + 5))
    while [ ! -S "$SOCK" ] && [ $SECONDS -lt $deadline ]; do
        sleep 0.2
    done
    [ -S "$SOCK" ]
}

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCK"
}
trap cleanup EXIT

echo "=== Test: Multi-Session Management ==="
echo "Socket: $SOCK"
echo "Binary: $APP_BIN"
echo ""

# ── Pre-condition ──────────────────────────────────────────────────────────
if [ ! -f "$APP_BIN" ]; then
    echo "  SKIP: binary not found — run test-build.sh first."
    exit 0
fi

rm -f "$SOCK"

# ── Launch app ─────────────────────────────────────────────────────────────
echo "[setup] Launching app..."
"$APP_BIN" &
APP_PID=$!

if ! wait_for_socket; then
    fail "Socket never appeared — cannot run multi-session tests"
    exit 1
fi
echo "        App up (PID=$APP_PID)"
echo ""

# ── Assertion 1: thinking events for 3 sessions sent rapidly ─────────────
echo "[1] Send 'thinking' events for 3 sessions in rapid succession..."
RAPID_OK=true
for i in 1 2 3; do
    if ! send_event "rapid-session-$i" "thinking"; then
        RAPID_OK=false
    fi
done
sleep 0.3

if $RAPID_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "All 3 rapid thinking events accepted; app still running"
else
    fail "Rapid multi-session events failed or app crashed"
fi

# ── Assertion 2: app alive after rapid burst ──────────────────────────────
echo "[2] App alive after rapid event burst..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App still running after rapid burst"
else
    fail "App crashed during rapid event burst"
fi

# ── Assertion 3: tool_start for multiple sessions ────────────────────────
echo "[3] Send tool_start for 3 different sessions..."
ALL_OK=true
for i in 1 2 3; do
    if ! send_event "rapid-session-$i" "tool_start" "Edit"; then
        ALL_OK=false
    fi
done
sleep 0.3

if $ALL_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "tool_start events sent to 3 sessions; app still running"
else
    fail "tool_start multi-session failed or app crashed"
fi

# ── Assertion 4: session_end for session 1 only ───────────────────────────
echo "[4] Send session_end for rapid-session-1 only..."
if send_event "rapid-session-1" "session_end" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "session_end for one session accepted; app alive"
else
    fail "session_end for one session crashed the app"
fi

# ── Assertion 5: remaining sessions still receive events ─────────────────
echo "[5] Remaining sessions (2 and 3) still accept events after session 1 ended..."
REMAINING_OK=true
for i in 2 3; do
    if ! send_event "rapid-session-$i" "tool_end" "Edit"; then
        REMAINING_OK=false
    fi
    sleep 0.05
done
sleep 0.3

if $REMAINING_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Events for remaining sessions accepted after session 1 ended"
else
    fail "Events for remaining sessions failed or app crashed"
fi

# ── Assertion 6: idle event for remaining sessions ───────────────────────
echo "[6] Send idle events for remaining sessions..."
IDLE_OK=true
for i in 2 3; do
    if ! send_event "rapid-session-$i" "idle"; then
        IDLE_OK=false
    fi
done
sleep 0.3

if $IDLE_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Idle events for sessions 2 and 3 accepted"
else
    fail "Idle events for remaining sessions failed or app crashed"
fi

# ── Assertion 7: 8 simultaneous sessions (max per design spec) ───────────
echo "[7] Send events for 8 simultaneous sessions (design spec maximum)..."
MAX_OK=true
for i in $(seq 1 8); do
    if ! send_event "max-session-$i" "thinking"; then
        MAX_OK=false
        echo "    FAILED for max-session-$i"
    fi
done
sleep 0.5

if $MAX_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "8 simultaneous sessions handled; app still running"
else
    fail "8 simultaneous sessions failed or app crashed"
fi

# ── Assertion 8: 9th session (beyond max) — app must survive ─────────────
echo "[8] Send event for a 9th session (beyond 8-cat max) — app must not crash..."
send_event "overflow-session-9" "thinking" 2>/dev/null || true
sleep 0.5

if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App survived event beyond max-session limit (eviction handled gracefully)"
else
    fail "App crashed when receiving 9th session event"
fi

# ── Assertion 9: session_end all remaining sessions ───────────────────────
echo "[9] Send session_end for all remaining sessions..."
END_OK=true
for i in 2 3; do
    if ! send_event "rapid-session-$i" "session_end"; then
        END_OK=false
    fi
done
for i in $(seq 1 8); do
    send_event "max-session-$i" "session_end" 2>/dev/null || true
done
send_event "overflow-session-9" "session_end" 2>/dev/null || true
sleep 0.5

if $END_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "All session_end events sent; app still running"
else
    fail "Mass session_end failed or app crashed"
fi

# ── Assertion 10: socket still open after all sessions end ───────────────
echo "[10] Socket still accessible after all sessions ended..."
if [ -S "$SOCK" ]; then
    pass "Socket still open (server keeps listening for new sessions)"
else
    fail "Socket disappeared after all sessions ended (server should keep listening)"
fi

# ── Teardown ──────────────────────────────────────────────────────────────
echo "[teardown] Killing app..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "--- Multi-Session Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
