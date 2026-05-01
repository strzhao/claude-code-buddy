# Knowledge Index

## Decisions
- [2026-04-27] isTransitioningOut 恢复策略采用时间戳超时 | tags: state-machine, transition, timeout, spritekit | → decisions.md
- [2026-04-23] AnimationTransitionManager 每猫实例而非单例 | tags: animation, spritekit, transition, personality | → decisions.md
- [2026-04-23] CatPersonality 随机生成不持久化 | tags: personality, random, persistence | → decisions.md
- [2026-04-19] 皮肤颜色变体采用 manifest variants 数组 | tags: skin, variant, manifest, architecture | → decisions.md
- [2026-04-21] 拖拽采用 DragComponent 组件而非新增 GKState | tags: architecture, drag, component, state-machine | → decisions.md
- [2026-04-19] Settings 面板点击通过 Panel.sendEvent 而非 NSCollectionView | tags: appkit, lsuielement, panel, click, settings | → decisions.md
- [2026-04-16] SkinPack 资源解析：builtIn(Bundle+Assets前缀) vs local(FileManager拼接) | tags: skin, resource, bundle, assets | → decisions.md
- [2026-04-16] Socket 双向通信：在现有 socket 上通过 action 字段扩展 | tags: socket, protocol, query, bidirectional | → decisions.md
- [2026-04-14] CLI 工具 Foundation-only 不依赖 BuddyCore | tags: cli, spm, spritekit, packaging | → decisions.md
- [2026-04-13] 猫咪朝向系统集中化 | tags: architecture, facing, movement | → decisions.md
- [2026-04-13] 活动边界采用逻辑约束而非窗口裁剪 | tags: window, bounds, dock | → decisions.md

## Patterns
- [2026-05-02] 外部修改 GKState 生命周期检查的标志位，绕过状态机 willExit 副作用决策 | tags: spritekit, gkstate, statemachine, willexit, side-effect, permission, flag | → patterns.md
- [2026-05-01] SKAction.wait 在子节点上 release build 中可能永远不触发，应统一用 GCD asyncAfter 替代 | tags: spritekit, skaction, wait, async, gcd, dispatch, release-build, state-machine, deadlock | → patterns.md
- [2026-05-01] 边界恢复中断 action 序列后需显式恢复被丢失的副作用（isDynamic 等） | tags: spritekit, skaction, boundary-recovery, sequence, interrupt, physics, isdynamic | → patterns.md
- [2026-05-01] 高频状态转换 + 食物通知触发 = 系统性漂移棘轮（三层防御：idle-only + 冷却 + 距离上限 + 最近单播） | tags: spritekit, food, state-machine, ratchet, drift, notification | → patterns.md
- [2026-05-01] 避让/排斥逻辑在边界处需双向逃离路径，否则形成死锁 | tags: spritekit, avoidance, boundary, deadlock, movement, adjusttarget | → patterns.md
- [2026-04-30] 障碍物路径检测容差向后延伸导致屏幕边缘跳跃死循环 | tags: spritekit, jump, obstacle, tolerance, boundary, movement, loop | → patterns.md
- [2026-04-29] JumpComponent snapGround no-op 导致猫咪 y 坐标累积漂移飞出屏幕 | tags: spritekit, physics, jump, y-coordinate, boundary-recovery, groundY | → patterns.md
- [2026-04-27] playFrightReaction removeAllActions 杀死 eating 动画导致永久卡死 | tags: spritekit, state-machine, eating, fright, race-condition, removeAllActions | → patterns.md
- [2026-04-26] smoothTurn 与即时位移并发导致反向行走 | tags: spritekit, animation, facing, movement, smoothturn, xscale | → patterns.md
- [2026-04-26] switchState Handoff 需要 display link 降级路径 | tags: spritekit, state-machine, transition, testing, display-link | → patterns.md
- [2026-04-23] smoothTurn 必须检查 display link 可用性 | tags: spritekit, animation, skaction, testing, display-link | → patterns.md
- [2026-04-23] SwiftLint large_tuple 用内部结构体替代多元组返回 | tags: swiftlint, tuples, struct, code-quality | → patterns.md
- [2026-04-20] SpriteKit 标签阴影常量命名与用法不一致导致阴影错位 | tags: spritekit, labels, shadow, constants, position | → patterns.md
- [2026-04-19] LSUIElement app 中 NSCollectionView 选择不工作，用 sendEvent 绕过 | tags: appkit, lsuielement, nscollectionview, key-window, click | → patterns.md
- [2026-04-19] 第三方精灵朝向需 manifest sprite_faces_right 声明 | tags: skin, sprite, facing, manifest | → patterns.md
- [2026-04-18] 中文标签间距需比拉丁字符预估值大 ~2 倍 | tags: spritekit, labels, spacing, cjk, font-size | → patterns.md
- [2026-04-19] 外部 sprite sheet → 皮肤包处理流水线（切帧/trim/缩放/画布对齐/manifest 校验） | tags: skin, sprite-sheet, pillow, upload, manifest, skin-pack | → patterns.md
- [2026-04-17] SpriteKit 物理碰撞掩码与 SKAction.moveTo 不兼容 | tags: spritekit, physics, collision, skaction, movement | → patterns.md
- [2026-04-16] CatEatingState 未实现 ResumableState，热替换需跳过 | tags: spritekit, state-machine, hotswap, eating, resumable | → patterns.md
- [2026-04-18] release.yml 与 bundle.sh 打包步骤不同步导致 CI 产物缺资源 | tags: ci, release, packaging, bundle, icon, if-guard, integrity-check | → patterns.md
- [2026-04-16] Unix socket write 必须循环处理部分写入 | tags: socket, posix, networking, write, partial-write | → patterns.md
- [2026-04-16] Plugin 缓存与源码不同步导致 hook 事件映射错误 | tags: plugin, cache, hooks, debugging, event-mapping | → patterns.md
- [2026-04-14] .app 内嵌 CLI 通过 Homebrew binary 指令暴露 PATH | tags: homebrew, cask, cli, packaging | → patterns.md
- [2026-04-13] SpriteKit moveBy 动画中断留下位置残留 | tags: spritekit, animation, switchState, moveBy | → patterns.md
- [2026-04-13] SPM Bundle.module 在 .app 打包中的正确路径 | tags: spm, bundle, resource, packaging, crash | → patterns.md
- [2026-04-16] 像素精灵图重处理需同步所有 UI 偏移和字号 | tags: spritekit, sprites, reprocessing, labels, constants | → patterns.md
- [2026-04-16] 测试中不应硬编码常量值来查找节点 | tags: testing, constants, spritekit, font-size | → patterns.md
- [2026-04-16] 垂直动画峰值由窗口高度和地面位置共同决定 | tags: window, bounds, animation, jump, physics | → patterns.md
- [2026-04-19] 精灵图 alpha 帧检测被粒子/特效残留误导 | tags: skin, sprite, slicing, alpha, frame-detection | → patterns.md
- [2026-04-21] switchState same-state guard 阻止拖拽后状态恢复 | tags: spritekit, state-machine, drag, same-state, restore | → patterns.md
- [2026-04-21] ignoresMouseEvents 在拖拽后未恢复导致窗口拦截点击 | tags: appkit, window, mouse-events, drag, click-through | → patterns.md
