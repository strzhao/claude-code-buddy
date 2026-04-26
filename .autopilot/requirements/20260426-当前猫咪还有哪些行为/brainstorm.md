# Brainstorm: 猫咪行为自然化

## 目标
优化猫咪行为的自然感和真实感，聚焦两个核心问题：状态转换生硬、移动不自然。

## 分析发现（Explore Agent）

### 8 大不自然行为
1. **状态转换生硬**: switchState() 瞬间 removeAllActions，easeOutHandoff 写好但从未使用
2. **缺少微行为**: 无耳朵抖动/尾巴/伸懒腰等细节，idle 只有 4 种子状态
3. **移动不自然**: 走路目标完全随机 (±120px)，动画帧率恒定不随速度变化
4. **环境感知缺失**: idleSleepWeightBoost 定义未消费，onTimeOfDayChanged 空方法
5. **缺少预期/反应**: anticipate() 从未被调用，食物走路没有嗅探动作
6. **可预测时间模式**: sleep 固定循环 3 次，breathe 固定等待 4±2s
7. **性格表达不足**: 4 个性格只映射到标量乘数，无质变行为差异
8. **状态机空洞**: CatEatingState.didEnter() 为空，fright anticipation 被 removeAllActions 取消

## 用户选择

### 优先方向
- [x] 状态转换生硬
- [ ] 缺少微行为
- [x] 移动不自然
- [ ] 环境感知缺失

### 状态转换方案: 渐进式 Handoff（框架化）
- 激活已有 easeOutHandoff: switchState 不再瞬间清除，先加速当前动画 0.15s 再混入新动画
- 各状态可在 willExit/didEnter 中插入自定义过渡（如 permissionRequest 退出时红色淡出）
- 风险: 动画 key 冲突需谨慎管理

### 移动方案: 速度曲线 + 渐进漫步
- 动画帧率与移动速度联动（慢=帧慢，快=帧快）
- 目标点改为渐进式漫步（小步幅 80%，中 15%，大 5%）
- 停顿时有减速+squash 过渡

### 实现约束
- 纯代码实现，不增加新精灵图帧
- 兼容所有现有皮肤包（内置 + 第三方）
- 使用 SKAction 缩放/旋转/速度变化实现自然感
