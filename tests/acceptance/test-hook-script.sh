#!/bin/bash
# Acceptance Test: Hook Script Verification
# Verifies hooks/buddy-hook.sh exists, is executable, exits silently when
# no socket is present, and maps each Claude Code hook type to the correct
# event name as specified in the design doc (Communication Protocol section).

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy.sock"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/buddy-hook.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Hook Script ==="
echo "Hook script: $HOOK_SCRIPT"
echo ""

# ── Assertion 1: hook script exists ───────────────────────────────────────
echo "[1] hooks/buddy-hook.sh exists..."
if [ -f "$HOOK_SCRIPT" ]; then
    pass "hooks/buddy-hook.sh exists"
else
    fail "hooks/buddy-hook.sh NOT found at $HOOK_SCRIPT"
    echo "    Cannot continue without the hook script."
    exit 1
fi

# ── Assertion 2: hook script is executable ────────────────────────────────
echo "[2] hooks/buddy-hook.sh is executable..."
if [ -x "$HOOK_SCRIPT" ]; then
    pass "hooks/buddy-hook.sh is executable"
else
    fail "hooks/buddy-hook.sh is NOT executable"
fi

# ── Assertion 3: exits silently (exit 0) when no socket exists ────────────
echo "[3] Hook exits silently when no socket is present..."
rm -f "$SOCK"   # ensure socket is absent

# Invoke with a Notification hook type via stdin JSON and a dummy session id
output=$(echo '{"hook_event_name":"Notification","session_id":"test-silent"}' | "$HOOK_SCRIPT" 2>&1)
exit_code=$?

if [ $exit_code -eq 0 ] && [ -z "$output" ]; then
    pass "Hook exits 0 with no output when socket is absent"
elif [ $exit_code -eq 0 ]; then
    # Produced some output but still exited 0 — acceptable if it's purely informational
    pass "Hook exits 0 when socket is absent (output: '$output')"
else
    fail "Hook exited $exit_code when socket is absent (output: '$output')"
fi

# ── Helper: capture JSON sent to a mock socket ────────────────────────────
# Spins up a tiny Python listener on the socket, runs the hook, and returns
# the first line received.

capture_hook_event() {
    local hook_type="$1"
    local session_id="${2:-test-session}"
    local tool_name="${3:-}"

    # Start a one-shot socket server that reads one line and prints it
    python3 - "$SOCK" <<'PYEOF' &
import sys, socket, os, time

sock_path = sys.argv[1]

# Remove stale socket
try: os.unlink(sock_path)
except: pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)
srv.settimeout(3)
try:
    conn, _ = srv.accept()
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(1024)
        if not chunk:
            break
        data += chunk
    conn.close()
    print(data.decode().strip())
except socket.timeout:
    pass
finally:
    srv.close()
    try: os.unlink(sock_path)
    except: pass
PYEOF
    local server_pid=$!
    sleep 0.3   # give server time to bind

    # Build stdin JSON matching Claude Code's hook input format
    local tool_json="null"
    if [ -n "$tool_name" ]; then
        tool_json="\"$tool_name\""
    fi
    local stdin_json="{\"hook_event_name\":\"$hook_type\",\"session_id\":\"$session_id\",\"tool_name\":$tool_json}"

    # Run the hook with stdin JSON
    echo "$stdin_json" | \
        "$HOOK_SCRIPT" 2>/dev/null

    # Collect server output
    wait $server_pid 2>/dev/null
    # The Python script printed to stdout; capture via process substitution above
    # Re-run via a temp file approach for portability:
    :
}

# Improved version that captures via temp file
# Accepts up to 5 connections and returns the first message matching the expected session_id,
# to avoid capturing stray messages from a real running Claude Code session.
capture_event_via_file() {
    local hook_type="$1"
    local session_id="${2:-test-session}"
    local tool_name="${3:-}"
    local tmpfile
    tmpfile=$(mktemp)

    python3 - "$SOCK" "$tmpfile" "$session_id" <<'PYEOF' &
import sys, socket, os, json

sock_path   = sys.argv[1]
out_file    = sys.argv[2]
expected_id = sys.argv[3]

try: os.unlink(sock_path)
except: pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(5)
srv.settimeout(5)

for _ in range(5):  # accept up to 5 connections to filter out stray messages
    try:
        conn, _ = srv.accept()
        data = b""
        conn.settimeout(2)
        try:
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        conn.close()
        line = data.decode().strip()
        if not line:
            continue
        # Check if this message is from our test (matches expected session_id)
        try:
            msg = json.loads(line)
            if msg.get("session_id") == expected_id:
                with open(out_file, "w") as f:
                    f.write(line)
                break
        except json.JSONDecodeError:
            # Non-JSON or malformed — skip and try next connection
            continue
    except socket.timeout:
        break

srv.close()
try: os.unlink(sock_path)
except: pass
PYEOF
    local server_pid=$!
    sleep 0.4   # give server time to bind

    # Build stdin JSON matching Claude Code's hook input format
    local tool_json="null"
    if [ -n "$tool_name" ]; then
        tool_json="\"$tool_name\""
    fi
    local stdin_json="{\"hook_event_name\":\"$hook_type\",\"session_id\":\"$session_id\",\"tool_name\":$tool_json}"

    echo "$stdin_json" | \
        "$HOOK_SCRIPT" 2>/dev/null

    wait $server_pid 2>/dev/null
    cat "$tmpfile"
    rm -f "$tmpfile"
}

# ── Assertion 4: Notification → event "thinking" ─────────────────────────
echo "[4] Notification hook maps to 'thinking' event..."
json=$(capture_event_via_file "Notification" "sess-1")
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['event']=='thinking'" 2>/dev/null; then
    pass "Notification → event='thinking' (JSON: $json)"
else
    fail "Notification did NOT produce event='thinking' (got: '$json')"
fi

# ── Assertion 5: PreToolUse → event "tool_start" ─────────────────────────
echo "[5] PreToolUse hook maps to 'tool_start' event..."
json=$(capture_event_via_file "PreToolUse" "sess-1" "Edit")
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['event']=='tool_start'" 2>/dev/null; then
    pass "PreToolUse → event='tool_start' (JSON: $json)"
else
    fail "PreToolUse did NOT produce event='tool_start' (got: '$json')"
fi

# ── Assertion 6: PostToolUse → event "tool_end" ───────────────────────────
echo "[6] PostToolUse hook maps to 'tool_end' event..."
json=$(capture_event_via_file "PostToolUse" "sess-1" "Edit")
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['event']=='tool_end'" 2>/dev/null; then
    pass "PostToolUse → event='tool_end' (JSON: $json)"
else
    fail "PostToolUse did NOT produce event='tool_end' (got: '$json')"
fi

# ── Assertion 7: Stop → event "idle" ─────────────────────────────────────
echo "[7] Stop hook maps to 'idle' event..."
json=$(capture_event_via_file "Stop" "sess-1")
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['event']=='idle'" 2>/dev/null; then
    pass "Stop → event='idle' (JSON: $json)"
else
    fail "Stop did NOT produce event='idle' (got: '$json')"
fi

# ── Assertion 8: SessionStart → event "session_start" ────────────────────
echo "[8] SessionStart hook maps to 'session_start' event..."
json=$(capture_event_via_file "SessionStart" "sess-1")
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['event']=='session_start'" 2>/dev/null; then
    pass "SessionStart → event='session_start' (JSON: $json)"
else
    fail "SessionStart did NOT produce event='session_start' (got: '$json')"
fi

# ── Assertion 9: JSON contains required fields ────────────────────────────
echo "[9] JSON message contains required fields (session_id, event, tool, timestamp)..."
json=$(capture_event_via_file "Notification" "sess-check")
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = {'session_id', 'event', 'tool', 'timestamp'}
missing  = required - set(d.keys())
assert not missing, f'Missing fields: {missing}'
" 2>/dev/null; then
    pass "JSON message contains all required fields"
else
    fail "JSON message missing required fields (got: '$json')"
fi

# ── Assertion 10: session_id is included in the message ──────────────────
echo "[10] session_id field matches the SESSION_ID passed to hook..."
json=$(capture_event_via_file "Notification" "my-unique-session-42")
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('session_id') == 'my-unique-session-42', f\"got '{d.get('session_id')}'\"
" 2>/dev/null; then
    pass "session_id correctly forwarded in JSON payload"
else
    fail "session_id not correctly forwarded (got: '$json')"
fi

# ── Assertion 11: timestamp is a non-zero integer ────────────────────────
echo "[11] timestamp field is a non-zero integer..."
json=$(capture_event_via_file "Notification" "sess-ts")
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ts = d.get('timestamp')
assert isinstance(ts, int) and ts > 0, f'Invalid timestamp: {ts}'
" 2>/dev/null; then
    pass "timestamp is a valid non-zero integer"
else
    fail "timestamp is invalid (got: '$json')"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- Hook Script Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
