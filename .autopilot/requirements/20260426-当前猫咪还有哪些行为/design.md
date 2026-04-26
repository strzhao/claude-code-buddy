# 设计文档：猫咪行为自然化

## 目标
优化猫咪状态转换和移动的自然感。纯代码实现（缩放/旋转/速度变化），不增加新精灵帧，兼容所有现有皮肤包。

## Part 1: 状态转换框架（渐进式 Handoff）
- `switchState()` 不再瞬间 `removeAllActions()`，改为 0.15s handoff 窗口
- containerNode 位置 action 立即停止，node 上的帧动画走加速逻辑
- 各状态通过 `prepareExitActions()` 插入自定义退出动画
- pending 使用 last-wins 单值模式，测试环境走即时路径

## Part 2: 自然移动（速度曲线 + 渐进漫步）
- 目标点从均匀 ±120px 改为加权分布（小步 80% / 中步 15% / 大步 5%）
- 帧率与移动速度联动（慢走帧慢，快走帧快）
- 起步前 2 帧慢速，停步有 squash 微动画
- 避免穿越其他猫（目标自动重定向到同侧）

## 附加修复
- 走路反向回归：smoothTurn 与 moveTo 并发竞争 xScale，走路时改为即时 snap
- 新增 2 个回归测试防止朝向问题再次出现

## 文件影响
| 文件 | 操作 | 说明 |
|------|------|------|
| CatConstants.swift | 修改 | +Transition enum, +Movement 渐进步幅常量 |
| CatSprite.swift | 修改 | switchState() 重写 + 3 辅助方法 + transition 属性 |
| 6 个 State 文件 | 修改 | +prepareExitActions() |
| MovementComponent.swift | 修改 | 目标选择+帧率+停步+障碍回避+朝向snap |
| CatPersonality.swift | 修改 | +stepSizeActivityShift |
| FacingDirectionTests.swift | 修改 | +2 回归测试 |
| claude-code-buddy.rb | 修改 | 版本号 0.15.0→0.16.0 |
