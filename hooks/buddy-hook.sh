#!/usr/bin/env bash
# buddy-hook.sh — Claude Code hook script for Claude Code Buddy
#
# Reads hook context from stdin JSON (provided by Claude Code),
# extracts session_id, hook_event_name, and tool_name,
# then sends a one-line JSON message to /tmp/claude-buddy.sock.
#
# Zero external dependencies — uses Python3 (macOS built-in).

SOCKET_PATH="${BUDDY_SOCKET_PATH:-/tmp/claude-buddy.sock}"

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
    cwd = d.get('cwd', '') or d.get('project_path', '')

    # Map hook event to buddy event
    m = {
        'SessionStart':    'session_start',
        'Notification':    'thinking',
        'UserPromptSubmit':'thinking',
        'PreToolUse':      'tool_start',
        'PostToolUse':     'tool_end',
        'PermissionRequest':'permission_request',
        'Stop':            'idle',
        'SessionEnd':      'session_end',
    }
    event = m.get(hook, 'idle')

    print(f'HOOK_EVENT=\"{hook}\"')
    print(f'SESSION_ID=\"{sid}\"')
    print(f'EVENT=\"{event}\"')
    print(f'TOOL_NAME={json.dumps(tool) if tool else \"null\"}')
    print(f'CWD="{cwd}"')
except:
    print('EVENT=\"idle\"')
    print('SESSION_ID=\"unknown\"')
    print('TOOL_NAME=null')
    print('CWD=\"\"')
" 2>/dev/null)"

# Fallback session ID
[ -z "$SESSION_ID" ] && SESSION_ID="$$"

TIMESTAMP=$(date +%s)

# Get Ghostty terminal ID on session_start (the focused terminal is the one that just launched Claude)
TERMINAL_ID=""
if [ "$EVENT" = "session_start" ]; then
    TERMINAL_ID=$(osascript -e '
      tell application "Ghostty"
        set t to selected tab of front window
        set term to focused terminal of t
        return id of term
      end tell
    ' 2>/dev/null)
fi

# Build and send JSON message via Unix domain socket
if [ "$TOOL_NAME" = "null" ] || [ -z "$TOOL_NAME" ]; then
    TOOL_JSON="null"
else
    TOOL_JSON="\"${TOOL_NAME}\""
fi

# Add cwd for session_start events
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
    CWD_JSON=",\"cwd\":\"${CWD}\""
else
    CWD_JSON=""
fi

# Add pid if found
if [ -n "$CLAUDE_PID" ]; then
    PID_JSON=",\"pid\":${CLAUDE_PID}"
else
    PID_JSON=""
fi
# Add terminal_id if found
if [ -n "$TERMINAL_ID" ]; then
    TID_JSON=",\"terminal_id\":\"${TERMINAL_ID}\""
else
    TID_JSON=""
fi
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"${EVENT}\",\"tool\":${TOOL_JSON},\"timestamp\":${TIMESTAMP}${CWD_JSON}${PID_JSON}${TID_JSON}}"

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

# Inject Ghostty tab title on SessionStart (async, non-blocking)
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
    LABEL="$(basename "$CWD")"
    osascript -e "
      tell application \"Ghostty\"
        repeat with t in terminals of every tab of every window
          if working directory of t is \"$CWD\" and name of t does not contain \"●\" then
            perform action \"set_tab_title:●${LABEL}\" on t
            return
          end if
        end repeat
      end tell
    " &>/dev/null &
fi

# AI awareness: output session identity info on SessionStart
if [ "$HOOK_EVENT" = "SessionStart" ]; then
    python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/claude-buddy-colors.json'))
    info = d.get('$SESSION_ID', {})
    if info:
        color_info = '颜色 = {} (●)，标签 = \"{}\"'.format(info['color'], info['label'])
        msg = '你的 Claude Code Buddy session：{}。如果当前任务有更好的描述名称，执行: buddy-label \"新名称\"'.format(color_info)
        print(json.dumps({'message': msg}))
except:
    pass
" 2>/dev/null
fi

exit 0
