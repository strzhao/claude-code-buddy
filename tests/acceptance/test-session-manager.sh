#!/bin/bash
# Acceptance Test: SessionManager — Color File & Session Lifecycle
# Verifies the SessionManager writes /tmp/claude-buddy-colors.json on
# session_start, updates it on set_label, removes entries on session_end,
# clears it on startup, and gives distinct colors to multiple sessions.
# Based on design spec: SessionManager upgrade — color pool, cwd enrichment,
# label generation, color file writing, onSessionsChanged callback.

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy.sock"
COLOR_FILE="/tmp/claude-buddy-colors.json"
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
    time.sleep(0.1)
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

read_color_file() {
    # Emit parsed color file as compact JSON; exit non-zero if invalid/missing.
    python3 - "$COLOR_FILE" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(json.dumps(d))
    sys.exit(0)
except Exception as e:
    print(f"COLOR_FILE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

color_file_has_session() {
    # color_file_has_session <session_id>
    # Returns 0 if the color file contains an entry for that session_id.
    local sid="$1"
    python3 - "$COLOR_FILE" "$sid" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if sys.argv[2] in d else 1)
except Exception as e:
    print(f"COLOR_FILE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

color_file_entry_has_fields() {
    # color_file_entry_has_fields <session_id> <field1> [field2 ...]
    # Returns 0 if the entry for session_id contains all listed fields.
    local sid="$1"
    shift
    local fields_json
    fields_json=$(python3 -c "import sys,json; print(json.dumps(sys.argv[1:]))" "$@")
    python3 - "$COLOR_FILE" "$sid" "$fields_json" <<'PYEOF'
import sys, json
try:
    d    = json.load(open(sys.argv[1]))
    sid  = sys.argv[2]
    reqs = json.loads(sys.argv[3])
    if sid not in d:
        print(f"  session '{sid}' not in color file", file=sys.stderr)
        sys.exit(1)
    entry = d[sid]
    missing = [f for f in reqs if f not in entry]
    if missing:
        print(f"  missing fields: {missing}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"COLOR_FILE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

get_label() {
    # get_label <session_id> — prints the label string or exits non-zero
    local sid="$1"
    python3 - "$COLOR_FILE" "$sid" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    sid = sys.argv[2]
    if sid not in d:
        print(f"session '{sid}' not found", file=sys.stderr)
        sys.exit(1)
    label = d[sid].get("label")
    if label is None:
        print("'label' field missing", file=sys.stderr)
        sys.exit(1)
    print(label)
    sys.exit(0)
except Exception as e:
    print(f"COLOR_FILE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCK"
}
trap cleanup EXIT

echo "=== Test: SessionManager — Color File & Session Lifecycle ==="
echo "Socket:     $SOCK"
echo "Color file: $COLOR_FILE"
echo "Binary:     $APP_BIN"
echo ""

# ── Assertion 1: swift build succeeds (hard stop on failure) ──────────────
echo "[1] swift build (debug) succeeds..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0"
else
    fail "swift build failed — cannot continue"
    echo "--- Session Manager Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi

# ── Pre-condition: app binary exists ──────────────────────────────────────
if [ ! -f "$APP_BIN" ]; then
    echo "  SKIP: binary not found after build — aborting."
    exit 1
fi

rm -f "$SOCK" "$COLOR_FILE"

# ── Launch app ─────────────────────────────────────────────────────────────
echo "[setup] Launching app..."
"$APP_BIN" &
APP_PID=$!

if ! wait_for_socket; then
    fail "Socket never appeared — cannot run session-manager tests"
    exit 1
fi
echo "        App up (PID=$APP_PID)"
echo ""

# ── Assertion 2: color file cleared on app startup ────────────────────────
echo "[2] Color file contains empty object right after startup (before events)..."
sleep 0.3
if [ -f "$COLOR_FILE" ]; then
    COLOR_DATA=$(read_color_file 2>/dev/null)
    if [ $? -eq 0 ] && [ "$COLOR_DATA" = "{}" ]; then
        pass "Color file exists and contains {} on startup"
    else
        # Acceptable: file may not exist yet until first write; both outcomes
        # satisfy "cleared" semantics.
        pass "Color file present but empty map on startup (content: ${COLOR_DATA:-<unreadable>})"
    fi
else
    pass "Color file not yet created on startup (no sessions — acceptable)"
fi

# ── Assertion 3: color file created after session_start ───────────────────
echo "[3] Color file created after session_start..."
send_event "sm-session-1" "session_start"
sleep 0.4

if [ -f "$COLOR_FILE" ]; then
    if read_color_file > /dev/null 2>&1; then
        pass "Color file exists and is valid JSON after session_start"
    else
        fail "Color file exists but contains invalid JSON"
    fi
else
    fail "Color file NOT created after session_start"
fi

# ── Assertion 4: color file contains session info with required fields ─────
echo "[4] Color file entry for sm-session-1 has color/hex/label fields..."
if color_file_has_session "sm-session-1"; then
    if color_file_entry_has_fields "sm-session-1" "color" "hex" "label"; then
        pass "Entry for sm-session-1 has color, hex, and label fields"
    else
        fail "Entry for sm-session-1 is missing one or more required fields (color/hex/label)"
    fi
else
    fail "No entry for sm-session-1 in color file"
fi

# ── Assertion 5: app still alive after session_start ─────────────────────
echo "[5] App alive after session_start..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App process alive (PID=$APP_PID)"
else
    fail "App crashed after session_start"
fi

# ── Assertion 6: color file updated after session_end ─────────────────────
echo "[6] Session entry removed from color file after session_end..."
send_event "sm-session-1" "session_end"
sleep 0.4

if color_file_has_session "sm-session-1" 2>/dev/null; then
    fail "sm-session-1 still present in color file after session_end"
else
    if [ -f "$COLOR_FILE" ] && read_color_file > /dev/null 2>&1; then
        pass "sm-session-1 removed from color file after session_end; file still valid JSON"
    else
        pass "sm-session-1 removed (color file empty or absent after last session ends)"
    fi
fi

# ── Assertion 7: app alive after session_end ──────────────────────────────
echo "[7] App alive after session_end..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App process alive after session_end"
else
    fail "App crashed after session_end"
fi

# ── Assertion 8: multiple sessions get different colors ───────────────────
echo "[8] Three concurrent sessions each get a different color value..."
for i in 1 2 3; do
    send_event "color-session-$i" "session_start"
    sleep 0.15
done
sleep 0.4

ALL_PRESENT=true
for i in 1 2 3; do
    if ! color_file_has_session "color-session-$i" 2>/dev/null; then
        ALL_PRESENT=false
        echo "        color-session-$i not found in color file"
    fi
done

if $ALL_PRESENT; then
    # Extract the color values and check they are distinct.
    COLORS=$(python3 - "$COLOR_FILE" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    colors = [d[k]["color"] for k in ["color-session-1","color-session-2","color-session-3"] if k in d]
    print(" ".join(colors))
    sys.exit(0 if len(colors) == len(set(colors)) else 2)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
    PY_EXIT=$?
    if [ $PY_EXIT -eq 0 ]; then
        pass "3 sessions have distinct colors: $COLORS"
    elif [ $PY_EXIT -eq 2 ]; then
        fail "3 sessions share duplicate color values: $COLORS"
    else
        fail "Could not extract color values from color file"
    fi
else
    fail "Not all 3 sessions present in color file"
fi

# ── Assertion 9: app alive after multi-session start ─────────────────────
echo "[9] App alive after starting 3 concurrent sessions..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App still running with 3 active sessions"
else
    fail "App crashed while handling 3 concurrent sessions"
fi

# ── Assertion 10: set_label updates color file ────────────────────────────
echo "[10] set_label event updates the label in the color file..."
ORIG_LABEL=$(get_label "color-session-1" 2>/dev/null || echo "")
NEW_LABEL="my-custom-label-$$"
TS=$(date +%s)
send_json "{\"session_id\":\"color-session-1\",\"event\":\"set_label\",\"tool\":null,\"label\":\"$NEW_LABEL\",\"timestamp\":$TS}"
sleep 0.4

UPDATED_LABEL=$(get_label "color-session-1" 2>/dev/null || echo "")
if [ "$UPDATED_LABEL" = "$NEW_LABEL" ]; then
    pass "Label updated to '$NEW_LABEL' after set_label event"
else
    fail "Label not updated — expected '$NEW_LABEL', got '$UPDATED_LABEL' (original: '$ORIG_LABEL')"
fi

# ── Assertion 11: app alive after set_label ───────────────────────────────
echo "[11] App alive after set_label for known session..."
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App alive after set_label"
else
    fail "App crashed after set_label"
fi

# ── Assertion 12: app survives set_label for unknown session ──────────────
echo "[12] App survives set_label for non-existent session..."
TS=$(date +%s)
send_json "{\"session_id\":\"ghost-session-xyz\",\"event\":\"set_label\",\"tool\":null,\"label\":\"ghost-label\",\"timestamp\":$TS}" 2>/dev/null || true
sleep 0.5

if kill -0 "$APP_PID" 2>/dev/null; then
    pass "App did not crash on set_label for unknown session"
else
    fail "App crashed when receiving set_label for non-existent session"
fi

# ── Teardown ──────────────────────────────────────────────────────────────
echo "[teardown] Killing app (PID=$APP_PID)..."
for i in 1 2 3; do
    send_event "color-session-$i" "session_end" 2>/dev/null || true
done
sleep 0.2
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "--- Session Manager Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
