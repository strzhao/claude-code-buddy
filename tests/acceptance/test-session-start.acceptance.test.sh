#!/bin/bash
# Acceptance Test: SessionStart Feature
# Verifies that the buddy-hook.sh correctly handles the SessionStart hook event
# as specified in the design doc:
#   - hook_event_name "SessionStart" in stdin JSON maps to event "session_start"
#   - output JSON format: {"session_id":"...","event":"session_start","tool":null,"timestamp":...}
#   - hooks.json registers the SessionStart hook
#   - Swift HookMessage.swift defines the sessionStart case
#   - graceful degradation when socket is absent
#   - multiple sessions produce independent events

set -euo pipefail

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy-test-$$.sock"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/buddy-hook.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Acceptance Test: SessionStart Feature ==="
echo "Hook script:  $HOOK_SCRIPT"
echo "Project root: $PROJECT_ROOT"
echo ""

# ── Guard: hook script must exist ─────────────────────────────────────────
if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "  FATAL: Hook script not found at $HOOK_SCRIPT — cannot run tests."
    exit 1
fi

# ── Helper: spin up a mock Unix socket, pipe JSON via stdin to the hook,
#    and return the first newline-terminated message received on the socket.
#
#    Usage: capture_stdin_event_via_file <stdin_json> [tmpfile]
#
#    The hook is invoked as:
#        echo '<stdin_json>' | buddy-hook.sh
# ──────────────────────────────────────────────────────────────────────────
capture_stdin_event_via_file() {
    local stdin_json="$1"
    local tmpfile
    tmpfile=$(mktemp)

    # One-shot Python socket server: binds, waits for one connection,
    # reads until newline, writes result to tmpfile.
    python3 - "$SOCK" "$tmpfile" <<'PYEOF' &
import sys, socket, os

sock_path = sys.argv[1]
out_file  = sys.argv[2]

try: os.unlink(sock_path)
except: pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)
srv.settimeout(5)
try:
    conn, _ = srv.accept()
    data = b""
    conn.settimeout(3)
    try:
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    conn.close()
    with open(out_file, "w") as f:
        f.write(data.decode().strip())
except socket.timeout:
    pass
finally:
    srv.close()
    try: os.unlink(sock_path)
    except: pass
PYEOF
    local server_pid=$!
    sleep 0.4   # give the server time to bind before the hook connects

    # Pipe the JSON payload to the hook via stdin
    echo "$stdin_json" | BUDDY_SOCKET_PATH="$SOCK" "$HOOK_SCRIPT" 2>/dev/null

    wait $server_pid 2>/dev/null
    cat "$tmpfile"
    rm -f "$tmpfile"
}

# ── Test 1: SessionStart stdin JSON maps to event "session_start" ─────────
echo "[1] SessionStart in stdin JSON maps to event 'session_start'..."
rm -f "$SOCK"
json=$(capture_stdin_event_via_file '{"hook_event_name":"SessionStart","session_id":"accept-test-001"}')

if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('event') == 'session_start', f\"event='{d.get('event')}', expected 'session_start'\"
" 2>/dev/null; then
    pass "SessionStart → event='session_start' (JSON: $json)"
else
    fail "SessionStart did NOT produce event='session_start' (got: '$json')"
fi

# ── Test 2: session_id from stdin is echoed back correctly ────────────────
echo "[2] session_id from stdin JSON is preserved in output..."
rm -f "$SOCK"
json=$(capture_stdin_event_via_file '{"hook_event_name":"SessionStart","session_id":"accept-test-001"}')

if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('session_id') == 'accept-test-001', f\"session_id='{d.get('session_id')}', expected 'accept-test-001'\"
" 2>/dev/null; then
    pass "session_id='accept-test-001' correctly forwarded (JSON: $json)"
else
    fail "session_id not forwarded correctly (got: '$json')"
fi

# ── Test 3: hooks.json contains SessionStart key ──────────────────────────
echo "[3] plugin/hooks/hooks.json contains a SessionStart entry..."
HOOKS_JSON="$PROJECT_ROOT/plugin/hooks/hooks.json"

if [ ! -f "$HOOKS_JSON" ]; then
    fail "hooks.json not found at $HOOKS_JSON"
else
    if python3 -c "
import sys, json
with open('$HOOKS_JSON') as f:
    d = json.load(f)
hooks = d.get('hooks', d)
assert 'SessionStart' in hooks, f'SessionStart key missing; keys={list(hooks.keys())}'
" 2>/dev/null; then
        pass "hooks.json contains a 'SessionStart' key"
    else
        fail "hooks.json does NOT contain a 'SessionStart' key"
    fi
fi

# ── Test 4: hooks.json SessionStart command references buddy-hook.sh ──────
echo "[4] SessionStart hook command references buddy-hook.sh..."
if [ -f "$HOOKS_JSON" ]; then
    if python3 -c "
import sys, json
with open('$HOOKS_JSON') as f:
    d = json.load(f)
hooks = d.get('hooks', d)
entry = hooks.get('SessionStart', [])
# entry is a list of matcher objects, each with a 'hooks' array containing command objects
cmds = []
if isinstance(entry, list):
    for matcher in entry:
        for h in matcher.get('hooks', []):
            cmds.append(h.get('command', ''))
elif isinstance(entry, dict):
    for h in entry.get('hooks', []):
        cmds.append(h.get('command', ''))
assert any('buddy-hook.sh' in c for c in cmds), f'buddy-hook.sh not in commands: {cmds}'
" 2>/dev/null; then
        pass "SessionStart hook command references buddy-hook.sh"
    else
        fail "SessionStart hook command does NOT reference buddy-hook.sh"
    fi
else
    fail "hooks.json not found — skipping command path check"
fi

# ── Test 5: Swift HookMessage.swift defines sessionStart case ─────────────
echo "[5] Sources/ClaudeCodeBuddy/Network/HookMessage.swift has 'sessionStart' case..."
HOOK_MSG_SWIFT="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Network/HookMessage.swift"

if [ ! -f "$HOOK_MSG_SWIFT" ]; then
    fail "HookMessage.swift not found at $HOOK_MSG_SWIFT"
else
    # Look for:   case sessionStart = "session_start"
    # (whitespace-flexible grep)
    if grep -qE 'case[[:space:]]+sessionStart[[:space:]]*=[[:space:]]*"session_start"' "$HOOK_MSG_SWIFT"; then
        pass "HookMessage.swift defines 'case sessionStart = \"session_start\"'"
    else
        fail "HookMessage.swift does NOT define 'case sessionStart = \"session_start\"'"
    fi
fi

# ── Test 6: Graceful degradation — exits 0 and produces no stdout ─────────
echo "[6] Hook exits 0 and produces no stdout when socket is absent..."
rm -f "$SOCK"

# Capture stdout only (stderr goes to /dev/null as before)
stdout_output=$(echo '{"hook_event_name":"SessionStart","session_id":"no-sock-test"}' \
    | BUDDY_SOCKET_PATH="$SOCK" "$HOOK_SCRIPT" 2>/dev/null)
exit_code=$?

if [ $exit_code -ne 0 ]; then
    fail "Hook exited $exit_code (expected 0) when socket is absent"
elif [ -n "$stdout_output" ]; then
    fail "Hook produced stdout output when socket is absent (stdout pollution breaks Claude Code): '$stdout_output'"
else
    pass "Hook exits 0 with empty stdout when socket is absent"
fi

# ── Test 7: Multiple sessions produce independent session_start events ─────
echo "[7] Multiple SessionStart events with distinct session_ids are all received..."

# We need a multi-connection mock server this time.
MULTI_TMPDIR=$(mktemp -d)

python3 - "$SOCK" "$MULTI_TMPDIR" <<'PYEOF' &
import sys, socket, os, json, threading

sock_path  = sys.argv[1]
out_dir    = sys.argv[2]
NUM        = 3

try: os.unlink(sock_path)
except: pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(NUM)
srv.settimeout(10)

def handle(conn, idx):
    data = b""
    conn.settimeout(3)
    try:
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    conn.close()
    with open(os.path.join(out_dir, f"msg_{idx}.json"), "w") as f:
        f.write(data.decode().strip())

threads = []
for i in range(NUM):
    try:
        conn, _ = srv.accept()
        t = threading.Thread(target=handle, args=(conn, i))
        t.start()
        threads.append(t)
    except socket.timeout:
        break

for t in threads:
    t.join()

srv.close()
try: os.unlink(sock_path)
except: pass
PYEOF
MULTI_SERVER_PID=$!
sleep 0.5   # let server bind

SESSION_IDS=("session-alpha" "session-beta" "session-gamma")
for sid in "${SESSION_IDS[@]}"; do
    echo "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$sid\"}" \
        | BUDDY_SOCKET_PATH="$SOCK" "$HOOK_SCRIPT" 2>/dev/null
    sleep 0.1  # slight stagger to avoid connection races
done

wait $MULTI_SERVER_PID 2>/dev/null

# Verify all 3 messages were received with correct content
all_ok=true
received_count=$(ls "$MULTI_TMPDIR"/msg_*.json 2>/dev/null | wc -l | tr -d ' ')

if [ "$received_count" -ne 3 ]; then
    fail "Expected 3 SessionStart events, but server received $received_count"
    all_ok=false
fi

if $all_ok; then
    for i in 0 1 2; do
        msg_file="$MULTI_TMPDIR/msg_${i}.json"
        if [ ! -f "$msg_file" ]; then
            fail "Missing message file $msg_file"
            all_ok=false
            continue
        fi

        # Verify event field
        if ! python3 -c "
import json
with open('$msg_file') as f:
    d = json.load(f)
assert d.get('event') == 'session_start', f\"event='{d.get('event')}'\"
" 2>/dev/null; then
            fail "Message $i: event field is not 'session_start' ($(cat "$msg_file"))"
            all_ok=false
        fi

        # Verify session_id field is non-empty and one of our known values
        if ! python3 -c "
import json
known = {'session-alpha','session-beta','session-gamma'}
with open('$msg_file') as f:
    d = json.load(f)
sid = d.get('session_id','')
assert sid in known, f\"unexpected session_id='{sid}'\"
" 2>/dev/null; then
            fail "Message $i: session_id is unexpected ($(cat "$msg_file"))"
            all_ok=false
        fi
    done
fi

if $all_ok; then
    # Collect all session_ids and verify they are 3 distinct values
    distinct=$(for f in "$MULTI_TMPDIR"/msg_*.json; do
        python3 -c "import json; d=json.load(open('$f')); print(d.get('session_id',''))" 2>/dev/null
    done | sort -u | wc -l | tr -d ' ')

    if [ "$distinct" -eq 3 ]; then
        pass "All 3 SessionStart events received with distinct session_ids"
    else
        fail "Expected 3 distinct session_ids, got $distinct"
    fi
fi

rm -rf "$MULTI_TMPDIR"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- SessionStart Acceptance Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
