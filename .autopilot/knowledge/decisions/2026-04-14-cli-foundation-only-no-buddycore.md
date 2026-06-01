# CLI 工具不依赖 BuddyCore 而使用 Foundation-only

<!-- tags: cli, spm, spritekit, packaging -->

**决策**: 新增的 `buddy` CLI 工具使用 Foundation-only 实现（不依赖 BuddyCore library target），独立定义 `BuddyMessage: Encodable` 结构体匹配 HookMessage 的 wire format。

**否决**: 让 CLI target 依赖 BuddyCore 以复用 HookMessage/HookEvent 类型。

**理由**:
- BuddyCore 内部导入了 SpriteKit/GameplayKit，会让 CLI 二进制膨胀 5-10x（app 二进制 732KB vs CLI 仅需 ~100KB）
- CLI 只需要编码 JSON 发送到 socket，不需要解码或 GUI 功能
- 消息格式非常稳定（9 个事件类型），维护一个 ~30 行的 Encodable 结构体成本低

**影响文件**: Sources/BuddyCLI/main.swift, Package.swift

**约束**: 如果 HookMessage 新增字段，CLI 的 BuddyMessage 也需同步更新。
