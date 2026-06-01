# 在现有 Unix domain socket 上扩展双向 query/response

<!-- tags: socket, protocol, query, bidirectional -->

**决策**: 在同一个 `/tmp/claude-buddy.sock` 上通过 `"action"` 字段区分查询消息和 Hook 消息，复用现有连接实现双向通信。

**否决**:
- Strategy A: 创建第二个 socket（如 `/tmp/claude-buddy-query.sock`）专门处理查询
- Strategy B: 通过共享文件（如 colors.json 扩展）暴露状态（数据过时，无实时性）

**理由**:
- SocketServer 已经跟踪 clientFD 和 per-client buffer，天然支持回写响应
- `"action"` 字段通过 `JSONSerialization.jsonObject` 检测，与 HookMessage 的 `JSONDecoder` 路径完全分离，不会冲突
- CLI 无需管理两个连接点，降低复杂度
- 未来新增查询类型只需在 QueryHandler 添加 switch case

**影响文件**: SocketServer.swift, QueryHandler.swift, SessionManager.swift, BuddyCLI/main.swift

**约束**: Hook 消息永远不应包含 `"action"` 字段。新增协议消息类型时必须保持这条分离规则。
