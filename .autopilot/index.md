# Knowledge Index

## Decisions
- [2026-04-19] 皮肤颜色变体采用 manifest variants 数组 | tags: skin, variant, manifest, architecture | → decisions.md
- [2026-04-21] 拖拽采用 DragComponent 组件而非新增 GKState | tags: architecture, drag, component, state-machine | → decisions.md
- [2026-04-19] Settings 面板点击通过 Panel.sendEvent 而非 NSCollectionView | tags: appkit, lsuielement, panel, click, settings | → decisions.md
- [2026-04-16] SkinPack 资源解析：builtIn(Bundle+Assets前缀) vs local(FileManager拼接) | tags: skin, resource, bundle, assets | → decisions.md
- [2026-04-16] Socket 双向通信：在现有 socket 上通过 action 字段扩展 | tags: socket, protocol, query, bidirectional | → decisions.md
- [2026-04-14] CLI 工具 Foundation-only 不依赖 BuddyCore | tags: cli, spm, spritekit, packaging | → decisions.md
- [2026-04-13] 猫咪朝向系统集中化 | tags: architecture, facing, movement | → decisions.md
- [2026-04-13] 活动边界采用逻辑约束而非窗口裁剪 | tags: window, bounds, dock | → decisions.md

## Patterns
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
