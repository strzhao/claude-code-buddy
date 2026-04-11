#!/usr/bin/env bash
# buddy-hook.sh — Claude Code hook script for Claude Code Buddy
#
# Reads hook context from stdin JSON (provided by Claude Code),
# extracts session_id, hook_event_name, and tool_name,
# then sends a one-line JSON message to /tmp/claude-buddy.sock.
#
# Zero external dependencies — uses Python3 (macOS built-in).

SOCKET_PATH="/tmp/claude-buddy.sock"

# Exit silently if the socket doesn't exist (buddy app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Read the full stdin JSON from Claude Code
HOOK_INPUT="$(cat)"

# Parse all needed fields from stdin JSON using Python3
eval "$(echo "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    hook = d.get('hook_event_name', '')
    sid  = d.get('session_id', '')
    tool = d.get('tool_name', '')

    # Map hook event to buddy event
    m = {
        'Notification':    'thinking',
        'UserPromptSubmit':'thinking',
        'PreToolUse':      'tool_start',
        'PostToolUse':     'tool_end',
        'Stop':            'idle',
        'SessionEnd':      'session_end',
    }
    event = m.get(hook, 'idle')

    print(f'HOOK_EVENT=\"{hook}\"')
    print(f'SESSION_ID=\"{sid}\"')
    print(f'EVENT=\"{event}\"')
    print(f'TOOL_NAME={json.dumps(tool) if tool else \"null\"}')
except:
    print('EVENT=\"idle\"')
    print('SESSION_ID=\"unknown\"')
    print('TOOL_NAME=null')
" 2>/dev/null)"

# Fallback session ID
[ -z "$SESSION_ID" ] && SESSION_ID="$$"

TIMESTAMP=$(date +%s)

# Build and send JSON message via Unix domain socket
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"${EVENT}\",\"tool\":${TOOL_NAME},\"timestamp\":${TIMESTAMP}}"

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
