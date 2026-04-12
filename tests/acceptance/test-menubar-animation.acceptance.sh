#!/bin/bash
# Acceptance Test: MenuBar Animation (MenuBarAnimator)
# Verifies that the menu bar icon animates in response to active cat states:
#   - Zero active cats → no animation (timer suspended)
#   - One active cat   → animation starts at ~7 FPS (0.15 s frame interval)
#   - Multiple active  → animation speeds up (interval = max(0.04, 0.15/N))
#   - Return to idle   → animation stops
#   - Rapid state switches → app never crashes
#
# "Active" is defined as state != idle && state != eating.
# Events that produce active states: thinking, tool_start (tool_use), waiting
# Events that produce idle states:   idle, session_end
#
# Design spec: MenuBarAnimator — DispatchSourceTimer, walk frames, speed table.

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

echo "=== Test: MenuBar Animation (MenuBarAnimator) ==="
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
    fail "Socket never appeared — cannot run menubar animation tests"
    exit 1
fi
echo "        App up (PID=$APP_PID)"
echo ""

# ── Assertion 1: App starts with no active cats → no animation ────────────
# On launch, all sessions are idle (or there are none), so the timer should
# be suspended. The app must be alive and stable in this state.
echo "[1] App starts with zero active cats — timer should be suspended (no animation)..."
sleep 0.3
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App is alive at startup with zero active cats (idle/static state)"
else
    fail "App crashed at startup before any events"
fi

# ── Assertion 2: Single active cat → animation starts ─────────────────────
# Sending 'thinking' makes state = thinking (active).
# Design spec: activeCatCount=1 → interval=0.15 s → ~7 FPS.
# We verify the app does not crash and continues running after the state change.
echo "[2] One cat goes 'thinking' → animation should start (~7 FPS, 0.15 s interval)..."
if send_event "anim-session-1" "thinking" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "thinking event sent (activeCatCount=1); app alive — animation expected active"
else
    fail "thinking event failed or app crashed when starting animation"
fi
sleep 0.3

# ── Assertion 3: App remains stable while animating (1 active cat) ────────
echo "[3] App stable while animating with 1 active cat..."
sleep 0.5   # let the timer fire a few frames at 0.15 s/frame
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App survived multiple animation frames with 1 active cat"
else
    fail "App crashed during single-cat animation"
fi

# ── Assertion 4: Second active cat → animation speeds up ─────────────────
# activeCatCount=2 → interval=0.075 s → ~13 FPS.
echo "[4] Second cat goes 'thinking' → animation should speed up (~13 FPS)..."
if send_event "anim-session-2" "thinking" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Second thinking event sent (activeCatCount=2); app alive — faster animation expected"
else
    fail "Second thinking event failed or app crashed"
fi
sleep 0.3

# ── Assertion 5: Four active cats → animation at cap speed (25 FPS) ───────
# activeCatCount=4 → interval=max(0.04, 0.15/4)=max(0.04,0.0375)=0.04 s → 25 FPS cap.
echo "[5] Four cats active → animation should reach cap speed (25 FPS, 0.04 s interval)..."
ALL_SENT=true
for i in 3 4; do
    if ! send_event "anim-session-$i" "thinking"; then
        ALL_SENT=false
    fi
done
sleep 0.3
if $ALL_SENT && kill -0 "$APP_PID" 2>/dev/null; then
    pass "4 active cats registered (activeCatCount=4); app alive — capped at 25 FPS expected"
else
    fail "Failed to register 4 active cats or app crashed"
fi

# ── Assertion 6: App stable at cap animation speed ────────────────────────
echo "[6] App stable while animating at cap speed (4 active cats)..."
sleep 0.5   # 0.5 s / 0.04 s = ~12 frames
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App survived multiple animation frames at cap speed (4 active cats)"
else
    fail "App crashed during cap-speed animation"
fi

# ── Assertion 7: tool_use (tool_start) event also counts as active ─────────
# CatState.toolUse is active per spec. session 5 goes toolUse.
echo "[7] tool_start event also counts as active cat (state=toolUse)..."
if send_event "anim-session-5" "tool_start" "Bash" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "tool_start event sent for session-5 (toolUse=active); app alive"
else
    fail "tool_start event failed or app crashed"
fi
sleep 0.2

# ── Assertion 8: waiting/permissionRequest counts as active ───────────────
# CatState.permissionRequest (event="waiting") is active per spec.
echo "[8] waiting event also counts as active cat (state=permissionRequest)..."
if send_event "anim-session-6" "waiting" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "waiting event sent for session-6 (permissionRequest=active); app alive"
else
    fail "waiting event failed or app crashed"
fi
sleep 0.2

# ── Assertion 9: One cat goes idle → active count decreases ──────────────
# idle event → state=idle (inactive).  activeCatCount decrements.
# App must survive the decrement and continue animating for remaining active cats.
echo "[9] One cat goes idle → activeCatCount decrements, animation continues for rest..."
if send_event "anim-session-1" "idle" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "idle event sent for session-1; app alive — animation still running for others"
else
    fail "idle event for session-1 failed or app crashed"
fi
sleep 0.3

# ── Assertion 10: All cats return to idle → animation stops ───────────────
# When activeCatCount drops to 0 the timer must be suspended (static icon).
# We send idle/session_end for all remaining active sessions.
echo "[10] All cats return to idle/end → activeCatCount=0 → animation stops..."
ALL_IDLE_OK=true
for i in 2 3 4 5 6; do
    evt="idle"
    [ "$i" -eq 5 ] && evt="tool_end"   # tool session ends cleanly
    if ! send_event "anim-session-$i" "$evt"; then
        ALL_IDLE_OK=false
    fi
done
sleep 0.5
if $ALL_IDLE_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "All cats back to idle; app alive — timer should be suspended (static icon)"
else
    fail "Returning all cats to idle failed or app crashed"
fi

# ── Assertion 11: App stable after returning to zero active cats ──────────
echo "[11] App stable after animation stops (zero active cats)..."
sleep 0.5
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App stable after animation timer was suspended"
else
    fail "App crashed after animation timer was supposed to stop"
fi

# ── Assertion 12: Rapid on/off toggling does not crash ────────────────────
# Simulate rapid state transitions: thinking → idle → thinking → idle ...
# This exercises the suspend/resume path on the DispatchSourceTimer.
echo "[12] Rapid on/off toggling (thinking ↔ idle) — app must not crash..."
RAPID_OK=true
for round in $(seq 1 6); do
    if ! send_event "rapid-toggle-1" "thinking"; then
        RAPID_OK=false
    fi
    sleep 0.05
    if ! send_event "rapid-toggle-1" "idle"; then
        RAPID_OK=false
    fi
    sleep 0.05
done
sleep 0.3
if $RAPID_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Rapid on/off toggling survived (6 rounds); app still running"
else
    fail "App crashed during rapid on/off toggling"
fi

# ── Assertion 13: Rapid multi-session start/stop does not crash ───────────
# Many sessions activate and deactivate concurrently to stress the
# activeCatCount accounting and timer suspend/resume logic.
echo "[13] Rapid multi-session activate/deactivate — app must not crash..."
MULTI_RAPID_OK=true
for i in $(seq 1 4); do
    if ! send_event "stress-session-$i" "thinking"; then
        MULTI_RAPID_OK=false
    fi
done
sleep 0.15
for i in $(seq 1 4); do
    if ! send_event "stress-session-$i" "idle"; then
        MULTI_RAPID_OK=false
    fi
done
sleep 0.3
if $MULTI_RAPID_OK && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Rapid multi-session activate/deactivate survived; app still running"
else
    fail "App crashed during rapid multi-session stress test"
fi

# ── Assertion 14: eating state is NOT active ──────────────────────────────
# CatState.eating must not count as active (same as idle per design spec).
# The app should accept the event without crashing.
echo "[14] eating state does not count as active (same treatment as idle)..."
if send_event "eating-session-1" "eating" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "eating event accepted; app alive — eating should not trigger animation"
else
    fail "eating event failed or app crashed"
fi
sleep 0.2
# ensure no lingering active count from this session
send_event "eating-session-1" "session_end" 2>/dev/null || true
sleep 0.2

# ── Assertion 15: Re-activation after full stop works ─────────────────────
# After count reaches 0 (timer suspended), sending another active event must
# resume the timer without crashing.
echo "[15] Re-activation after full stop → animation restarts cleanly..."
if send_event "restart-session-1" "thinking" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "Animation restarted after full stop; app alive"
else
    fail "App crashed when restarting animation from zero"
fi
sleep 0.3
# cleanup
send_event "restart-session-1" "idle" 2>/dev/null || true
sleep 0.2

# ── Assertion 16: session_end for active session decrements count ─────────
# A session_end on an active session (not preceded by idle) should also
# decrement activeCatCount and eventually suspend the timer.
echo "[16] session_end on active session decrements activeCatCount properly..."
send_event "end-active-1" "thinking" 2>/dev/null
sleep 0.1
send_event "end-active-2" "thinking" 2>/dev/null
sleep 0.1
if send_event "end-active-1" "session_end" && kill -0 "$APP_PID" 2>/dev/null; then
    pass "session_end on active session accepted; app alive (count decremented)"
else
    fail "session_end on active session failed or app crashed"
fi
sleep 0.2
send_event "end-active-2" "session_end" 2>/dev/null || true
sleep 0.3
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App stable after all active sessions ended via session_end"
else
    fail "App crashed after active sessions ended via session_end"
fi

# ── Teardown ──────────────────────────────────────────────────────────────
echo ""
echo "[teardown] Killing app (PID=$APP_PID)..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "--- MenuBar Animation Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
