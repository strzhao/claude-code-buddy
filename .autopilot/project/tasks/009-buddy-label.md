---
id: "009-buddy-label"
depends_on: ["002-session-manager", "004-hook-script"]
---

## 目标

创建 buddy-label CLI 脚本，允许 AI 或用户通过命令行更新会话标签。

## 架构上下文

AI 可以通过执行 `buddy-label "新名称"` 来更新当前会话的标签。脚本发送 set_label 消息到 socket，SessionManager 处理后更新 CatSprite 标签和颜色文件。

## 关键实现细节

### buddy-label.sh (`plugin/scripts/buddy-label.sh`)

约 20 行 bash 脚本：

```bash
#!/usr/bin/env bash
# Usage: buddy-label "新标签名"
LABEL="$1"
SOCKET_PATH="${BUDDY_SOCKET_PATH:-/tmp/claude-buddy.sock}"

[ -S "$SOCKET_PATH" ] || { echo "Buddy app not running"; exit 1; }
[ -z "$LABEL" ] && { echo "Usage: buddy-label <label>"; exit 1; }

# 查找当前 session_id（通过 PID 祖先链匹配 ~/.claude/sessions/）
SESSION_ID=$(python3 -c "
import os, json, glob
ppid = os.getppid()
for f in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')):
    try:
        d = json.load(open(f))
        if d.get('pid') == ppid or d.get('ppid') == ppid:
            print(d.get('session_id', ''))
            break
    except: pass
")

[ -z "$SESSION_ID" ] && { echo "Cannot determine session ID"; exit 1; }

TIMESTAMP=$(date +%s)
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"set_label\",\"label\":\"${LABEL}\",\"timestamp\":${TIMESTAMP}}"

python3 - "$SOCKET_PATH" "$JSON" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
s.close()
PYEOF

# 同步更新 Ghostty 标签页标题
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
```

### hooks.json 变更

无需变更 — buddy-label 不是 hook 事件，是独立 CLI 工具。

### SessionManager 已在 002 中处理 set_label

002 任务已包含 `.setLabel` 事件的处理逻辑，本任务无需修改 Swift 代码。

## 输入/输出契约

**输入来自 002：** SessionManager 的 set_label 处理逻辑

**输入来自 004：** hook 脚本的 socket 通信模式（Python3 socket 代码复用）

## 验收标准

- [ ] buddy-label.sh 可执行
- [ ] 无参数时显示用法提示
- [ ] Socket 不存在时优雅退出
- [ ] 正确发送 set_label JSON 到 socket
- [ ] Ghostty 标签页标题同步更新
- [ ] 从 Claude Code 会话中能正确检测 session_id
