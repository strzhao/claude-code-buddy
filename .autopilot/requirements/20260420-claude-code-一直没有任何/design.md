# 设计文档：猫咪超时消失修复

- **目标**：猫咪在 Claude Code 进程存活期间不会因超时消失，进程退出后自动清理
- **技术方案**：注册缺失 UserPromptSubmit hook + 发送 PID + kill(pid,0) 进程存活检测替代硬超时
- **超时策略**：5min→idle / 30min+进程活→保留 / 30min+进程死或无PID→删除

## 变更文件
| 文件 | 操作 | 说明 |
|------|------|------|
| `plugin/hooks/hooks.json` | 添加 | 注册 UserPromptSubmit hook |
| `plugin/scripts/buddy-hook.sh` | 修改 | 添加 pid 字段到 socket 消息 |
| `hooks/buddy-hook.sh` | 修改 | 同步 pid 字段（本地副本） |
| `SessionManager.swift` | 修改 | isProcessAlive + checkTimeouts 重写 |
| 测试文件 x3 | 修改/新增 | 超时测试更新 + 红队验收测试 |
