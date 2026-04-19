# Brainstorm: Token 驱动猫咪缩放

## 目标
让猫咪的大小随着 token 的使用量逐渐增大，类似游戏等级系统。

## Q&A 决策记录

### Q1: 空间策略 — 窗口高度限制如何处理
**选择**: 动态升高窗口
- 猫变大时自动增加窗口高度（如 80→100→120→150pt）
- 猫始终完整可见，标签有空间
- 需要联动 DockTracker/BuddyWindow/BuddyScene

### Q2: 缩放梯度设计
**选择**: 离散等级制
- 到达阈值时触发明确的"升级"动画
- 闪光 + 缩放动画 (0.5s)
- 变大后永久保持

### Q3: Token 展示方式
**选择**: Hover 时显示 + 升级弹窗
- 平时无额外标签，保持简洁
- 鼠标悬停时显示 "Lv3 | 1.2M tokens"
- 升级瞬间弹出 "Lv3 ↑ 1.2M" 浮窗标签（2-3s 后淡出）

### Q4: 极端数据处理
**选择**: 延伸等级 + 软封顶
- 5M 以上继续缓慢增长至 Lv8 (1.8x)
- 50M+ token 封顶

## 等级表设计

| 等级 | Token 范围 | 缩放 | 窗口高度 |
|------|-----------|------|---------|
| Lv1 | 0 - 0.5M | 1.0x | 80pt |
| Lv2 | 0.5M - 1M | 1.1x | 88pt |
| Lv3 | 1M - 2M | 1.2x | 96pt |
| Lv4 | 2M - 5M | 1.35x | 108pt |
| Lv5 | 5M - 10M | 1.5x | 120pt |
| Lv6 | 10M - 20M | 1.6x | 128pt |
| Lv7 | 20M - 50M | 1.7x | 136pt |
| Lv8 | 50M+ | 1.8x | 150pt |

## 技术要点

- **Token 数据源**: SessionInfo.totalTokens 已存在，TranscriptReader 每 10s 更新
- **缩放目标**: containerNode.setScale() — 世界空间缩放
- **与 hover 缩放的协调**: hover 基于当前 token scale 乘以 1.25
- **窗口联动**: DockTracker.buddyWindowFrame(height:) 需动态传入
- **物理体**: 需随缩放更新碰撞体大小
- **标签系统**: 新增 token info 节点，处理缩放后的标签补偿
