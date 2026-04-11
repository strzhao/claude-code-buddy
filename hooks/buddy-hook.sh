#!/usr/bin/env bash
# buddy-hook.sh — Claude Code hook script for Claude Code Buddy
#
# Install by adding to your Claude Code hooks config:
#   "hooks": {
#     "Notification": [{"hooks": [{"type": "command", "command": "/path/to/buddy-hook.sh"}]}],
#     "PreToolUse":   [{"hooks": [{"type": "command", "command": "/path/to/buddy-hook.sh"}]}],
#     "PostToolUse":  [{"hooks": [{"type": "command", "command": "/path/to/buddy-hook.sh"}]}],
#     "Stop":         [{"hooks": [{"type": "command", "command": "/path/to/buddy-hook.sh"}]}]
#   }
#
# The script reads the Claude Code hook context from stdin (JSON) and
# sends a one-line JSON message to /tmp/claude-buddy.sock using Python3.

SOCKET_PATH="/tmp/claude-buddy.sock"

# Exit silently if the socket doesn't exist (app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Determine event type from the CLAUDE_HOOK_TYPE env var set by Claude Code.
# Fall back to inspecting the hook name if not set.
HOOK_TYPE="${CLAUDE_HOOK_TYPE:-}"

# Read stdin so we don't block the hook pipeline
HOOK_INPUT="$(cat)"

# Map hook type to event
case "$HOOK_TYPE" in
    Notification) EVENT="thinking"   ;;
    PreToolUse)   EVENT="tool_start" ;;
    PostToolUse)  EVENT="tool_end"   ;;
    Stop)         EVENT="idle"       ;;
    *)            EVENT="idle"       ;;
esac

# Extract tool name from stdin JSON if available (optional, best-effort)
TOOL_NAME="null"
if command -v python3 &>/dev/null && [ -n "$HOOK_INPUT" ]; then
    TOOL_NAME=$(echo "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    t = d.get('tool_name') or d.get('tool') or ''
    print(json.dumps(t) if t else 'null')
except:
    print('null')
" 2>/dev/null) || TOOL_NAME="null"
fi

# Session ID: prefer CLAUDE_SESSION_ID, then SESSION_ID, fall back to PID
SESSION_ID="${CLAUDE_SESSION_ID:-${SESSION_ID:-$$}}"
TIMESTAMP=$(date +%s)

# Build JSON message (one line, newline-terminated)
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"${EVENT}\",\"tool\":${TOOL_NAME},\"timestamp\":${TIMESTAMP}}"

# Send via Python3 using Unix domain socket (no external dependencies)
python3 - "$SOCKET_PATH" "$JSON" 2>/dev/null <<'PYEOF'
import socket, sys

sock_path = sys.argv[1]
message   = sys.argv[2] + "\n"

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    s.connect(sock_path)
    s.sendall(message.encode("utf-8"))
    s.close()
except Exception:
    pass
PYEOF

exit 0
