# AnimationTransitionManager 采用每猫实例而非单例

<!-- tags: animation, spritekit, transition, personality -->

**决策**: AnimationTransitionManager 由每只 CatSprite 在 init 中创建并持有（`unowned` 引用 node/containerNode/personality），不做全局单例。

**否决**: 全局单例 AnimationTransitionManager，接受 node 引用参数。

**理由**:
- 单例持有 `unowned` 引用多只猫的 node，生命周期管理复杂（猫移除时需手动清理）
- 每猫实例天然隔离状态，无需管理共享 action key 命名空间
- 实例创建成本极低（仅存储引用 + personality 值），8 只猫 8 个实例无性能问题
- 与 DragComponent、InteractionComponent 等现有组件模式一致（每实体独立实例）

**影响文件**: AnimationTransitionManager.swift(新建), CatSprite.swift

**约束**: AnimationTransitionManager 只通过 `unowned` 引用外部节点，不拥有任何节点。新增强化动画方法时必须保持在 0.15-0.3s 范围内以避免状态切换冲突。
