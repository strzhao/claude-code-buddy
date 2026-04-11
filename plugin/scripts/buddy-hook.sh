#!/usr/bin/env bash
# buddy-hook.sh — Claude Code hook script for Claude Code Buddy
#
# Reads hook context from stdin JSON (provided by Claude Code),
# builds a socket message, and sends it to /tmp/claude-buddy.sock.
#
# All JSON construction is done in Python to avoid shell escaping issues.

SOCKET_PATH="${BUDDY_SOCKET_PATH:-/tmp/claude-buddy.sock}"

# Exit silently if the socket doesn't exist (buddy app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Read the full stdin JSON from Claude Code
HOOK_INPUT="$(cat)"

# Get hook event name (needed to decide whether to fetch terminal ID)
HOOK_EVENT_NAME="$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hook_event_name',''))" 2>/dev/null)"

# Get Ghostty terminal ID on SessionStart
TERMINAL_ID=""
if [ "$HOOK_EVENT_NAME" = "SessionStart" ]; then
    TERMINAL_ID=$(osascript -e '
      tell application "Ghostty"
        set t to selected tab of front window
        set term to focused terminal of t
        return id of term
      end tell
    ' 2>/dev/null)
fi

# Python does all JSON building, socket sending, and AI awareness output
echo "$HOOK_INPUT" | python3 - "$SOCKET_PATH" "$TERMINAL_ID" <<'PYEOF'
import sys, json, socket, time, subprocess, os

sock_path = sys.argv[1]
terminal_id = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""

try:
    d = json.load(sys.stdin)
except:
    sys.exit(0)

hook = d.get("hook_event_name", "")
sid = d.get("session_id", "") or str(d.get("pid", "unknown"))
tool = d.get("tool_name", "")
cwd = d.get("cwd", "") or d.get("project_path", "")
tool_input = d.get("tool_input", {})
desc = tool_input.get("description", "") if isinstance(tool_input, dict) else ""

event_map = {
    "SessionStart":      "session_start",
    "Notification":      "thinking",
    "UserPromptSubmit":  "thinking",
    "PreToolUse":        "tool_start",
    "PostToolUse":       "tool_end",
    "PermissionRequest": "permission_request",
    "Stop":              "idle",
    "SessionEnd":        "session_end",
}
event = event_map.get(hook, "idle")

msg = {
    "session_id": sid,
    "event": event,
    "timestamp": int(time.time()),
}
if tool:
    msg["tool"] = tool
if cwd and event == "session_start":
    msg["cwd"] = cwd
if terminal_id:
    msg["terminal_id"] = terminal_id
if desc:
    msg["description"] = desc

payload = json.dumps(msg, ensure_ascii=False) + "\n"

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    s.connect(sock_path)
    s.sendall(payload.encode("utf-8"))
    s.close()
except:
    pass

# AI awareness on SessionStart
if hook == "SessionStart":
    try:
        colors = json.load(open("/tmp/claude-buddy-colors.json"))
        info = colors.get(sid, {})
        if info:
            color_info = f"颜色 = {info['color']} (●)，标签 = \"{info['label']}\""
            out_msg = f"你的 Claude Code Buddy session：{color_info}。如果当前任务有更好的描述名称，执行: buddy-label \"新名称\""
            print(json.dumps({"message": out_msg}))
    except:
        pass

# Inject Ghostty tab title on SessionStart
if hook == "SessionStart" and cwd:
    label = os.path.basename(cwd)
    script = f'''
      tell application "Ghostty"
        repeat with t in terminals of every tab of every window
          if working directory of t is "{cwd}" and name of t does not contain "●" then
            perform action "set_tab_title:●{label}" on t
            return
          end if
        end repeat
      end tell
    '''
    subprocess.Popen(["osascript", "-e", script],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PYEOF

exit 0
