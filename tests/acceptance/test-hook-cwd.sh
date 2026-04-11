#!/bin/bash
# Acceptance Test: cwd Extraction + Ghostty Tab Title Injection
# Verifies task 004-hook-script behaviour in hooks/buddy-hook.sh:
#   1. SessionStart events include the "cwd" field in the JSON payload.
#   2. Non-SessionStart events do NOT include a "cwd" field.
#   3. SessionStart without a cwd field in stdin gracefully omits cwd from JSON.
#   4. hooks/buddy-hook.sh and plugin/scripts/buddy-hook.sh are identical.
#   5. A Ghostty tab-title injection block exists in the hook script.
#   6. The Ghostty osascript block is invoked asynchronously (& operator).

PASS=0
FAIL=0
SOCK="/tmp/claude-buddy.sock"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/buddy-hook.sh"
PLUGIN_HOOK="$PROJECT_ROOT/plugin/scripts/buddy-hook.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: cwd Extraction + Ghostty Tab Title Injection ==="
echo "Hook script: $HOOK_SCRIPT"
echo ""

# ── Prerequisite: hook script must exist ─────────────────────────────────────
if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "  FATAL: $HOOK_SCRIPT not found — cannot continue."
    exit 1
fi

# ── Helper: spin up a mock socket, pipe stdin JSON to the hook, capture output ─
# Args:
#   $1 — raw JSON string to feed via stdin
#   $2 — session_id used to filter the captured message (must match what's in $1)
# Prints the first JSON line received that matches the session_id.
capture_with_stdin() {
    local stdin_json="$1"
    local session_id="$2"
    local tmpfile
    tmpfile=$(mktemp)

    # One-shot Python socket server — writes the matching line to tmpfile
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

for _ in range(5):
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
        try:
            msg = json.loads(line)
            if msg.get("session_id") == expected_id:
                with open(out_file, "w") as f:
                    f.write(line)
                break
        except json.JSONDecodeError:
            continue
    except socket.timeout:
        break

srv.close()
try: os.unlink(sock_path)
except: pass
PYEOF
    local server_pid=$!
    sleep 0.4   # give server time to bind

    echo "$stdin_json" | "$HOOK_SCRIPT" 2>/dev/null

    wait $server_pid 2>/dev/null
    cat "$tmpfile"
    rm -f "$tmpfile"
}

# ── Assertion 1: SessionStart with cwd includes cwd in JSON ──────────────────
echo "[1] SessionStart with cwd includes cwd in JSON payload..."
json=$(capture_with_stdin \
    '{"hook_event_name":"SessionStart","session_id":"cwd-test-1","cwd":"/tmp/test-project"}' \
    "cwd-test-1")
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('cwd') == '/tmp/test-project', f\"cwd mismatch: got '{d.get('cwd')}' in {d}\"
" 2>/dev/null; then
    pass "SessionStart includes cwd='/tmp/test-project' (JSON: $json)"
else
    fail "SessionStart did NOT include correct cwd (got: '$json')"
fi

# ── Assertion 2: Non-SessionStart event does NOT include cwd ─────────────────
echo "[2] Non-SessionStart (Notification) event does NOT include cwd..."
json=$(capture_with_stdin \
    '{"hook_event_name":"Notification","session_id":"cwd-test-2","cwd":"/tmp/test-project"}' \
    "cwd-test-2")
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'cwd' not in d, f\"Unexpected cwd field present: {d}\"
" 2>/dev/null; then
    pass "Notification event does not include cwd field (JSON: $json)"
else
    fail "Notification event unexpectedly contains cwd (got: '$json')"
fi

# ── Assertion 3: SessionStart without cwd gracefully omits cwd ───────────────
echo "[3] SessionStart without cwd in stdin gracefully omits cwd from JSON..."
json=$(capture_with_stdin \
    '{"hook_event_name":"SessionStart","session_id":"cwd-test-3"}' \
    "cwd-test-3")
# The JSON must be valid and must NOT contain a "cwd" key
if echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'cwd' not in d, f\"Unexpected cwd field: {d}\"
assert d.get('event') == 'session_start', f\"Wrong event: {d}\"
" 2>/dev/null; then
    pass "SessionStart without cwd produces valid JSON without cwd field (JSON: $json)"
else
    fail "SessionStart without cwd produced unexpected result (got: '$json')"
fi

# ── Assertion 4: Both hook files are identical ────────────────────────────────
echo "[4] hooks/buddy-hook.sh and plugin/scripts/buddy-hook.sh are identical..."
if [ ! -f "$PLUGIN_HOOK" ]; then
    fail "plugin/scripts/buddy-hook.sh not found at $PLUGIN_HOOK"
elif diff -q "$HOOK_SCRIPT" "$PLUGIN_HOOK" >/dev/null 2>&1; then
    pass "hooks/buddy-hook.sh and plugin/scripts/buddy-hook.sh are identical"
else
    fail "hooks/buddy-hook.sh and plugin/scripts/buddy-hook.sh differ"
    diff "$HOOK_SCRIPT" "$PLUGIN_HOOK" | head -20
fi

# ── Assertion 5: Ghostty AppleScript block exists in the hook script ──────────
echo "[5] Ghostty tab-title injection block exists in hook script..."
if grep -q "Ghostty" "$HOOK_SCRIPT" && grep -q "set_tab_title\|set tab title\|SetTitle\|SetUserVar" "$HOOK_SCRIPT"; then
    pass "Ghostty tab-title injection block found in hook script"
else
    fail "Ghostty tab-title injection block NOT found in hook script"
fi

# ── Assertion 6: Ghostty osascript block is async (&) ────────────────────────
echo "[6] Ghostty osascript block is invoked asynchronously (& operator)..."
# Look for 'osascript' followed (on same or adjacent line) by '&' indicating
# background execution.  A trailing '&' on the osascript call itself or on the
# closing line of a subshell/block satisfies this check.
if grep -q '&>/dev/null &' "$HOOK_SCRIPT"; then
    pass "osascript block is invoked asynchronously with & operator"
else
    fail "osascript block does NOT appear to be async (no trailing & found)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "--- cwd + Ghostty Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
