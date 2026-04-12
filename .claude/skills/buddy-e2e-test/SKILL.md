---
name: buddy-e2e-test
description: "手动 E2E 测试 Claude Code Buddy app。仅限用户显式调用（/buddy-e2e-test），不要自动触发——执行成本高（构建+启动+全量场景约 5 分钟）。"
user-invocable: true
---

# Buddy E2E Test

真实启动 app，真实发送事件，真实验证行为。不是模拟，不是断言源码——是运行中的 app 对外部刺激的响应。

## 与 shell 验收测试的分工

`tests/acceptance/` 覆盖：构建、hook 脚本映射、socket 协议存活、数据模型静态检查、多会话并发存活。

**本 skill 聚焦 acceptance tests 未覆盖的缺口**：
- `permission_request` 完整流程（含 description 展示、badge、恢复）
- 超过 socket 读缓冲区的大 payload（跨 `read()` 调用的缓冲区重组）
- label 截断保护（超长 description 不崩溃）
- Color file 损坏恢复
- 状态转换动画的视觉正确性

## Phase 1: 动态发现

**不要硬编码测试参数。** 从源码实时读取：

```
读取 HookMessage.swift → 提取所有 HookEvent case 和 catState 映射
读取 SessionColor.swift → 提取颜色数量 = 最大并发数
读取 SocketServer.swift → 提取 socket 路径、读缓冲区大小
读取 SessionManager.swift → 提取超时值、color file 路径
读取 CatSprite.swift → 提取截断阈值、状态转换动画映射
读取 BuddyScene.swift → 提取 maxCats 值
扫描 tests/acceptance/ → 识别已有覆盖，排除重复
```

将发现结果计算为测试参数：

| 参数 | 来源 | 示例 |
|------|------|------|
| `EVENT_TYPES` | HookEvent enum cases | `[session_start, thinking, ...]` |
| `MAX_SESSIONS` | SessionColor.allCases.count | `8` |
| `SOCKET_PATH` | SocketServer.socketPath | `/tmp/claude-buddy.sock` |
| `READ_BUFFER` | SocketServer read() 参数 | `4096` |
| `LABEL_TRUNCATE` | CatSprite showLabel 截断阈值 | `80` |
| `COLOR_FILE` | SessionManager 写入路径 | `/tmp/claude-buddy-colors.json` |
| `EXISTING_COVERAGE` | tests/acceptance/ 覆盖的事件 | 排除已测事件组合 |

## Phase 2: 基础设施

```bash
# 清理残留
pkill ClaudeCodeBuddy 2>/dev/null
rm -f $SOCKET_PATH $COLOR_FILE

# 构建（必须成功，否则终止）
swift build || exit 1

# 后台启动 + 日志捕获
nohup .build/debug/ClaudeCodeBuddy > /tmp/buddy-test.log 2>&1 &
APP_PID=$!

# 等待 socket（超时 10s 则失败）
timeout 10 bash -c "until [ -S $SOCKET_PATH ]; do sleep 0.5; done" || {
  echo "FATAL: socket not ready"; kill $APP_PID; exit 1
}
```

发送 helper：`echo '{"..."}' | nc -U $SOCKET_PATH`（echo 自动追加 `\n`）

## Phase 3: 场景生成与执行

基于 Phase 1 发现的参数，生成以下场景类别。每个场景**必须有明确的验证断言**。

### 类别 A: 每个事件类型的基础通路

对 `EVENT_TYPES` 中的**每一个**事件，发送一条合法消息，验证：
- 日志出现 `Decoded message: event=X, session=Y`
- 无 `JSON decode error`
- 进程存活

### 类别 B: 完整状态机路径

覆盖**每一个** catState 非 nil 的事件类型组成的完整会话流：
```
session_start → [每个状态至少经过一次] → session_end
```
验证：日志完整 + color file 先增后删 + 进程存活

### 类别 C: acceptance test 缺口补全

这是本 skill 的核心价值。针对 Phase 1 识别出的覆盖缺口生成场景：

1. **permission_request 完整流程**：含 description → 视觉确认 badge → tool_start 恢复
2. **大 payload**：description 长度 > `READ_BUFFER` 字节（跨 read 边界）
3. **label 截断边界**：description 恰好 `LABEL_TRUNCATE` 字符 vs `LABEL_TRUNCATE + 1` 字符
4. **Color file 损坏**：写入垃圾数据后发 session_start
5. **EOF 刷新路径**：发送不带 `\n` 的消息后关闭连接
6. **其他发现的缺口**

### 类别 D: 边界值与异常

- `MAX_SESSIONS` 个并发会话：每个分配不同颜色
- 第 `MAX_SESSIONS + 1` 个：验证 eviction 行为
- 每个必要字段单独缺失：session_id、event、timestamp
- 格式错误 JSON + 未知 event 值
- 同 ID 重复 session_start

## Phase 4: 验证标准

### 分层验证（由强到弱）

| 层级 | 方法 | 证明力 |
|------|------|--------|
| **V1 日志断言** | `grep` 精确匹配 Decoded message | 证明消息被接收和解码 |
| **V2 状态文件断言** | `python3 -c` 解析 color file JSON | 证明会话管理逻辑正确 |
| **V3 错误路径断言** | `grep "JSON decode error"` | 证明错误被优雅处理 |
| **V4 进程存活断言** | `pgrep ClaudeCodeBuddy` | 证明无崩溃 |
| **V5 视觉验证** | 目视 Dock 区域动画 | 唯一的状态机视觉验证手段 |

### 零容忍标准

```
所有场景必须 PASS。没有 P2 豁免。没有"记录但不阻断"。
任何 FAIL = 测试未通过，必须修复后重跑失败场景。
App 崩溃 = 严重 BUG，立即停止测试并报告。
```

**每个场景执行后立即验证**，不要攒到最后批量检查。

### V1-V4 是客观验证，V5 是补充验证

日志只能证明"消息被接收"，不能证明"猫咪进入了正确动画"。对于状态机行为（thinking 的 paw 动画、permission_request 的红色 badge、toolUse 的随机行走），**必须在日志验证通过后，额外进行 V5 视觉确认**。如果无法目视（headless 环境），在报告中明确标注"V5 未验证"。

## Phase 5: 报告

```markdown
## E2E 测试报告 — {日期}
### 环境
- 构建: {debug/release}
- 源码发现: {EVENT_TYPES 数量} 个事件, {MAX_SESSIONS} 并发上限, {READ_BUFFER}B 缓冲

### 结果
| 类别 | 场景数 | PASS | FAIL |
|------|--------|------|------|
| A 基础通路 | {n} | {n} | 0 |
| B 状态机路径 | {n} | {n} | 0 |
| C 缺口补全 | {n} | {n} | 0 |
| D 边界异常 | {n} | {n} | 0 |

### 失败详情（如有）
{场景名}: {期望} vs {实际} — {日志/截图证据}

### 发现的 BUG
{编号}: {描述} — {根因} — {崩溃日志/复现步骤}
```

## 常见错误

| 错误 | 后果 |
|------|------|
| 硬编码事件列表而不读源码 | 新增事件类型时遗漏测试 |
| 只检查日志不检查 color file | 消息收到了但会话管理可能坏了 |
| 批量发送后才检查 | 无法定位哪条消息导致问题 |
| 跳过 V5 视觉验证不标注 | 状态机 BUG 被遗漏 |
| 允许某些场景失败 | 边界 BUG 积累直到生产崩溃 |
| Wave 之间不清理会话 | 状态污染导致后续场景假性失败 |
