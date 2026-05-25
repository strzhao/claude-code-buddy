#!/bin/bash
# Acceptance Test: Unix Domain Socket Protocol
# Verifies the socket server (at /tmp/claude-buddy.sock) accepts connections,
# handles valid JSON messages, survives malformed input, and cleans up on exit.
# Based on design spec: Communication Protocol section.

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy.sock"
APP_PID=""
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BIN="$PROJECT_ROOT/.build/debug/ClaudeCodeBuddy"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── Helpers ────────────────────────────────────────────────────────────────

send_json() {
    # Send a single JSON line to the socket; returns 0 on success.
    local json="$1"
    python3 - "$SOCK" "$json" <<'PYEOF'
import sys, socket, time

sock_path = sys.argv[1]
message   = sys.argv[2]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sock_path)
    s.sendall((message + "\n").encode())
    time.sleep(0.1)   # give the server a moment to process
    s.close()
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

wait_for_socket() {
    # Poll until socket file appears (up to 5 s).
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
}
trap cleanup EXIT

echo "=== Test: Unix Domain Socket Protocol ==="
echo "Socket path: $SOCK"
echo "App binary:  $APP_BIN"
echo ""

# ── Pre-condition: app binary exists ───────────────────────────────────────
if [ ! -f "$APP_BIN" ]; then
    echo "  SKIP: binary not found — run test-build.sh first."
    exit 0
fi

# Remove any stale socket from a previous run
rm -f "$SOCK"

# ── Start the app in the background ────────────────────────────────────────
echo "[setup] Launching app in background..."
"$APP_BIN" &
APP_PID=$!
echo "        PID=$APP_PID"

# ── Assertion 1: socket file appears within 5 s ────────────────────────────
echo "[1] Socket file created at $SOCK..."
if wait_for_socket; then
    pass "Socket file exists at /tmp/claude-buddy.sock"
else
    fail "Socket file did NOT appear within 5 s"
    exit 1   # nothing else can run without the socket
fi

# ── Assertion 2: app is still running after socket creation ───────────────
echo "[2] App process is still running..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App process alive (PID=$APP_PID)"
else
    fail "App process died immediately after socket creation"
fi

# ── Assertion 3: valid JSON — thinking event ───────────────────────────────
echo "[3] Send valid JSON 'thinking' event..."
MSG='{"session_id":"test1","event":"thinking","tool":null,"timestamp":1713000000}'
if send_json "$MSG"; then
    pass "Valid thinking event accepted without error"
else
    fail "Failed to send valid thinking event"
fi

# ── Assertion 4: app still running after valid message ────────────────────
echo "[4] App still alive after valid message..."
sleep 0.3
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App did not crash after valid message"
else
    fail "App crashed after valid message"
fi

# ── Assertion 5: malformed JSON — app must not crash ──────────────────────
echo "[5] Send malformed JSON — app must survive..."
if send_json "this is not json at all }{"; then
    echo "        (socket accepted connection)"
fi
sleep 0.5
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App did not crash on malformed JSON"
else
    fail "App crashed on malformed JSON"
fi

# ── Assertion 6: send events for multiple sessions ────────────────────────
echo "[6] Send events for 3 different session_ids..."
MULTI_OK=true
for sid in "session-A" "session-B" "session-C"; do
    msg="{\"session_id\":\"$sid\",\"event\":\"thinking\",\"tool\":null,\"timestamp\":1713000001}"
    if ! send_json "$msg"; then
        MULTI_OK=false
        echo "        FAILED for session: $sid"
    fi
done
sleep 0.3
if $MULTI_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Multi-session events sent and app still running"
else
    fail "Multi-session events failed or app crashed"
fi

# ── Assertion 7: tool_start event (coding state) ──────────────────────────
echo "[7] Send tool_start event..."
MSG='{"session_id":"test1","event":"tool_start","tool":"Edit","timestamp":1713000002}'
if send_json "$MSG" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "tool_start event accepted, app still running"
else
    fail "tool_start event failed or app crashed"
fi

# ── Assertion 8: tool_end event ───────────────────────────────────────────
echo "[8] Send tool_end event..."
MSG='{"session_id":"test1","event":"tool_end","tool":"Edit","timestamp":1713000003}'
if send_json "$MSG" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "tool_end event accepted, app still running"
else
    fail "tool_end event failed or app crashed"
fi

# ── Assertion 9: idle event ───────────────────────────────────────────────
echo "[9] Send idle event..."
MSG='{"session_id":"test1","event":"idle","tool":null,"timestamp":1713000004}'
if send_json "$MSG" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "idle event accepted, app still running"
else
    fail "idle event failed or app crashed"
fi

# ── Assertion 10: session_end event ───────────────────────────────────────
echo "[10] Send session_end event..."
MSG='{"session_id":"test1","event":"session_end","tool":null,"timestamp":1713000005}'
if send_json "$MSG" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "session_end event accepted, app still running"
else
    fail "session_end event failed or app crashed"
fi

# ── Assertion 11: socket file still exists after session_end ──────────────
echo "[11] Socket file still present after session_end (server still running)..."
if [ -S "$SOCK" ]; then
    pass "Socket file still exists (server keeps listening for other sessions)"
else
    fail "Socket file disappeared prematurely after single session_end"
fi

# ── Kill the app ───────────────────────────────────────────────────────────
echo "[teardown] Killing app (PID=$APP_PID)..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
sleep 0.5

# ── Assertion 12: socket file cleaned up after app exits ──────────────────
echo "[12] Socket file cleaned up after app exits..."
if [ ! -e "$SOCK" ]; then
    pass "Socket file removed after app exit"
else
    fail "Socket file still exists after app exit (stale socket)"
    rm -f "$SOCK"   # clean up for subsequent runs
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- Socket Protocol Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
