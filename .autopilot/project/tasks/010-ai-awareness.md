---
id: "010-ai-awareness"
depends_on: ["002-session-manager", "004-hook-script"]
---

## 目标

让 AI 在会话开始时知道自己的 Buddy 颜色和标签，并提供 buddy-label 的使用提示。同时提供终端状态栏集成指南。

## 架构上下文

hook 脚本在 SessionStart 事件时可以返回 message 字段，注入到 AI 的上下文中。AI 需要知道自己的颜色标识和 buddy-label 工具的存在。

已知限制：首次 SessionStart 时 `/tmp/claude-buddy-colors.json` 中尚无当前会话条目（Swift 端还未处理完消息），AI 在第二条消息后才能获取准确信息。

## 关键实现细节

### hook 脚本 SessionStart 响应

在 buddy-hook.sh 中，当事件为 SessionStart 时，读取颜色文件并返回消息：

```bash
if [ "$EVENT" = "session_start" ]; then
    # 读取颜色文件获取当前会话的颜色
    COLOR_INFO=""
    if [ -f /tmp/claude-buddy-colors.json ]; then
        COLOR_INFO=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/claude-buddy-colors.json'))
    info = d.get('$SESSION_ID', {})
    if info:
        print(f'颜色 = {info[\"color\"]} (●)，标签 = \"{info[\"label\"]}\"')
except: pass
" 2>/dev/null)
    fi
    
    if [ -n "$COLOR_INFO" ]; then
        # 输出到 stdout（Claude Code hook 的 message 机制）
        echo "{\"message\": \"你的 Claude Code Buddy session：${COLOR_INFO}。如果当前任务有更好的描述名称，执行: buddy-label \\\"新名称\\\"\"}"
    fi
fi
```

### 状态栏集成

提供 statusline 脚本示例或文档，指导用户修改 `~/.claude/statusline-command.sh`：

```bash
# 读取颜色文件，显示 ● label
if [ -f /tmp/claude-buddy-colors.json ]; then
    BUDDY_INFO=$(python3 -c "
import json, os
try:
    d = json.load(open('/tmp/claude-buddy-colors.json'))
    sid = os.environ.get('CLAUDE_SESSION_ID', '')
    info = d.get(sid, {})
    if info:
        print(f'● {info[\"label\"]}')
except: pass
" 2>/dev/null)
    [ -n "$BUDDY_INFO" ] && echo -n "$BUDDY_INFO | "
fi
```

## 输入/输出契约

**输入来自 002：** /tmp/claude-buddy-colors.json 文件格式

**输入来自 004：** hook 脚本结构和 SessionStart 事件处理

## 验收标准

- [ ] SessionStart hook 返回包含颜色和标签的 message（当颜色文件中有对应条目时）
- [ ] SessionStart hook 在颜色文件中无条目时不返回 message（不报错）
- [ ] message 中包含 buddy-label 使用提示
- [ ] 状态栏集成脚本示例可运行
- [ ] 现有 hook 功能不受影响
