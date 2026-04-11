#!/usr/bin/env bash
# buddy-label.sh — Set a custom label for the current Claude Code Buddy session
# Usage: buddy-label "新标签名"

LABEL="$1"
SOCKET_PATH="${BUDDY_SOCKET_PATH:-/tmp/claude-buddy.sock}"

[ -z "$LABEL" ] && { echo "Usage: buddy-label <label>" >&2; exit 1; }
[ -S "$SOCKET_PATH" ] || { echo "Buddy app not running" >&2; exit 1; }

# Find current session_id by matching PID ancestry against ~/.claude/sessions/
SESSION_ID=$(python3 -c "
import os, json, glob

ppid = os.getppid()
# Walk up the process tree
pids_to_check = [ppid]
try:
    # Also check grandparent
    with open(f'/proc/{ppid}/stat') as f:
        parts = f.read().split()
        pids_to_check.append(int(parts[3]))
except:
    pass

for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
    try:
        with open(f) as fh:
            d = json.load(fh)
        sess_pid = d.get('pid')
        if sess_pid in pids_to_check:
            print(d.get('session_id', ''))
            break
    except:
        pass
" 2>/dev/null)

# If we couldn't find the session ID, try the CLAUDE_SESSION_ID env var
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-}"
[ -z "$SESSION_ID" ] && { echo "Cannot determine session ID" >&2; exit 1; }

TIMESTAMP=$(date +%s)
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"set_label\",\"label\":\"${LABEL}\",\"timestamp\":${TIMESTAMP}}"

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

# Update Ghostty tab title (async, non-blocking)
CWD="$(pwd)"
osascript -e "
  tell application \"Ghostty\"
    repeat with t in terminals of every tab of every window
      if working directory of t is \"$CWD\" then
        perform action \"set_tab_title:●${LABEL}\" on t
        return
      end if
    end repeat
  end tell
" &>/dev/null &

echo "Label set to: $LABEL"
