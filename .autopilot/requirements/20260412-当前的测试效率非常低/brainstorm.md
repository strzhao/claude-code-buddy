# Brainstorm: AI 可自我验证测试方案

## Q&A 摘要

### Q1: 「AI 可自我验证」的核心含义
**答**: 两者都要，且测试执行要快
- AI 改代码后能自动跑测试确认没破坏
- 测试覆盖率要足够高覆盖核心业务逻辑
- 执行速度要快（秒级），不拖慢 autopilot 循环

### Q2: 重构意愿
**答**: 允许中等重构
- 可以引入 SceneControlling 等协议抽象
- 可以拆解 SessionManager 耦合
- 可以重构 EventBus 单例
- 不需要做到极致的依赖注入（如时间源注入等）

### Q3: 测试运行器偏好
**答**: 统一为 swift test
- 现有 shell 验收测试迁移到 XCTest
- 集成测试也用 XCTest（通过 Process 启动 app 二进制 + socket 交互）
- 统一入口，AI 最容易解析结果

### Q4: 落地策略
**答**: 分阶段，先单元后集成
- 先解锁核心逻辑可测试性（SessionManager 抽象 + 单元测试）
- 再将 shell 集成测试迁移为 XCTest
- 每步都可验证

## 方案选择

**方案 A: 协议抽象 + 统一迁移**（用户确认）

核心思路：
1. 引入 SceneControlling 协议解耦 SessionManager → BuddyScene
2. 为 SessionManager 核心逻辑添加 MockScene 单元测试
3. 补充 TranscriptReader/EventBus/状态机转换等纯逻辑测试
4. 将 shell 集成测试迁移为 XCTest Process-based 测试
5. 统一 swift test 入口，总耗时 <10s
6. 预估覆盖率从 ~15% 提升到 ~65%

## 现状数据

- 现有 XCTest: 56 个，覆盖纯值类型
- 现有 shell 验收: 16+ 个脚本，很多未纳入主运行器
- 核心 SessionManager ~300 行完全无单元测试
- 项目 ~25-30% 代码是纯逻辑，70-75% 与 SpriteKit 耦合
- 诊断报告测试维度评分: 2/10
