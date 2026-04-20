# Brainstorm: 猫咪长按拖拽功能

## 需求澄清 Q&A

### Q1: 长按触发阈值
**选择**: 0.3 秒 — 与 iOS 长按拖拽体验一致

### Q2: 拖拽范围
**选择**: 允许全屏拖拽 — 忽略 activityBounds 约束，松手后猫咪自己走回活动区域

### Q3: 下落效果
**选择**: 自由落体 + 弹跳 — 松手后从当前高度自由落体到地面，触地时 1-2 次小弹跳，配合 scared 表情

### Q4: 拖拽动画
**选择**: 专属 grabbed 动画 — 皮肤包新增 "grabbed" 动画名称配置，旧皮肤降级使用 "scared" 动画

### Q5: 多猫处理
**选择**: 单只拖拽 — 一次只拖一只猫，按点击位置找最近的猫

### Q6: 放下后状态
**选择**: 恢复拖拽前状态 — 落地弹跳完成后，恢复到拖拽前的业务状态（thinking/tool_use 等）

### Q7: 架构方案
**选择**: 新增 DragComponent — 作为物理交互组件，暂停状态机而非新增 GKState，与 InteractionComponent 的 fright reaction 模式一致

## 关键设计决策

1. **MouseTracker 扩展**: 在 localMonitor 中新增 leftMouseDragged/leftMouseUp 事件监听
2. **ignoresMouseEvents 保持**: 拖拽期间必须保持 false，取消 leaveTimer
3. **皮肤包 manifest 扩展**: animation_names 新增可选 "grabbed"，落在 AnimationComponent 中做降级
4. **落地物理**: 使用 SKAction.customAction 模拟自由落体 + 弹跳阻尼，参考 JumpComponent 的弧线实现
5. **边界恢复**: 落地后若在 activityBounds 外，触发 walkBackIntoBounds
