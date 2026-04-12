# 行为架构重构 — 深度设计 Q&A 记录

## Q1: 近期实体类型
**问**: 近期（1-3个月内）计划加入哪些新的实体类型？
**答**: 仅猫（短期内）。先把猫的行为系统做扎实，新动物以后再说。
**设计影响**: 不需要立即实现多实体工厂，但架构需要留好 EntityProtocol 扩展点。

## Q2: 重构策略
**问**: 渐进式重构还是一次性重写？
**答**: 渐进式重构（每步可运行）。
**设计影响**: 8 个独立任务串行执行，每个任务必须编译通过 + 测试通过。

## Q3: 状态机实现
**问**: GKStateMachine vs 自建 Swift 状态机 vs 优化现有 enum？
**答**: GKStateMachine。
**设计影响**: 需要解决 GKStateMachine 同步 enter() 与异步 SKAction 过渡动画的冲突（选择方案 A：didEnter 内启动过渡动画）。

## Q4: 事件系统
**问**: Combine vs 自建 EventBus vs 保持回调模式？
**答**: Combine。
**设计影响**: EventBus 使用 PassthroughSubject，Apple 原生框架，类型安全。

## Q5: 本次范围
**问**: 完成哪些阶段？
**答**: 全部 4 个阶段（状态机重构 + 组件拆分 + 事件系统 + 环境框架）。
**设计影响**: 8 个串行任务，预计工作量 L 级别。

## 行业调研结论

- Shimeji-ee、Desktop Goose 等桌面宠物应用都**没有用 ECS**——核心场景是"少量实体 + 丰富行为"
- GKStateMachine 比 GKBehavior/GKGoal 更适合 SKAction 驱动的离散动画
- 完整 ECS (GKEntity/GKComponent) 对 1-8 个差异化实体过度工程
- 推荐路线：GKStateMachine + 轻量组件组合 + Combine EventBus
