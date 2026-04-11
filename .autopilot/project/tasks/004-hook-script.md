---
id: "004-hook-script"
depends_on: ["001-data-models"]
---

## 目标

增强 hook 脚本以提取 cwd 并在首次消息中发送，同时注入 Ghostty 标签页标题。

## 架构上下文

当前 buddy-hook.sh 从 Claude Code stdin JSON 提取 hook_event_name, session_id, tool_name。需要新增 cwd 提取和 Ghostty 标签页标题注入。

需要同步修改两份文件（内容完全相同）：
- `hooks/buddy-hook.sh`
- `plugin/scripts/buddy-hook.sh`

## 关键实现细节

### cwd 提取

Claude Code 的 stdin JSON 中包含项目路径信息。在 Python 解析部分新增：
```python
cwd = d.get('cwd', '') or d.get('project_path', '')
print(f'CWD="{cwd}"')
```

### 首次消息 cwd 携带

JSON 消息新增 cwd 字段（仅在 SessionStart 时或首次消息时携带）：
```bash
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
    CWD_JSON=",\"cwd\":\"${CWD}\""
else
    CWD_JSON=""
fi
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"${EVENT}\",\"tool\":${TOOL_JSON},\"timestamp\":${TIMESTAMP}${CWD_JSON}}"
```

### Ghostty 标签页标题注入

在 SessionStart 事件时异步设置 Ghostty 标签页标题：
```bash
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
```

`&` 确保异步执行，不阻塞 hook 返回。

## 输入/输出契约

**输入来自 001：** HookMessage JSON 格式（cwd 字段定义）

**输出给 007：** Ghostty 标签页标题格式约定 `●{label}`

**输出给 009/010：** hook 脚本结构（新事件、新字段的添加模式）

## 验收标准

- [ ] hooks/buddy-hook.sh 和 plugin/scripts/buddy-hook.sh 内容一致
- [ ] SessionStart 消息包含 cwd 字段
- [ ] 非 SessionStart 消息不包含 cwd 字段
- [ ] 无 cwd 可用时优雅降级（不崩溃，不包含空 cwd）
- [ ] Ghostty 标签页标题异步设置，不阻塞 hook 返回
- [ ] 现有测试 test-hook-script.sh 仍通过
