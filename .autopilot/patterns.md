# Patterns & Lessons

### [2026-04-17] SpriteKit 物理碰撞掩码与 SKAction.moveTo 不兼容
<!-- tags: spritekit, physics, collision, skaction, movement -->
**Scenario**: 多只猫设置了 `collisionBitMask = .cat`，但实际移动用 `SKAction.moveTo(x:)` 直接设位置，绕过物理引擎
**Lesson**: `SKAction.moveTo/moveBy` 直接修改节点 position，不经过物理引擎的碰撞检测。如果需要实体间防重叠，必须在 update 循环中用代码实现（如弹簧阻尼软分离），而非依赖 SpriteKit 物理碰撞。物理碰撞只在纯物理驱动（施加力/速度）时有效。
**Evidence**: CatSprite.collisionBitMask 设了 .cat 但猫咪仍然穿越重叠。改用 applySoftSeparation() 帧更新推力后解决。

### [2026-04-16] 像素精灵图重处理需同步所有 UI 偏移和字号
<!-- tags: spritekit, sprites, reprocessing, labels, constants -->
**Scenario**: 像素精灵图（48×48 画布）的实际内容远小于画布，需要裁剪透明填充并缩放
**Lesson**: 裁剪+缩放精灵图后，所有基于精灵大小的 UI 元素必须同步调整：标签 Y 偏移、tooltip 位置、字号、徽章尺寸、物理体大小。遗漏任何一项都会导致视觉错位。精灵图变更时用 grep 搜索所有引用精灵尺寸的常量。
**Evidence**: 精灵图从 ~20px 可见内容缩放到 48×48 后，TooltipNode Y 偏移仍为 +2（重叠猫咪身体），需改为 +26；食物渲染大小从 12 改为 24 后生成位置也需从 +12 改为 +24。

### [2026-04-16] 测试中不应硬编码常量值来查找节点
<!-- tags: testing, constants, spritekit, font-size -->
**Scenario**: 单元测试通过 fontSize==9 来查找 SpriteKit 标签节点，当常量从 9 改为 12 后测试全部崩溃
**Lesson**: 测试中查找节点应引用常量（如 CatConstants.Visual.tabLabelFontSize）而非硬编码魔法数字。常量变更时测试自然会使用新值，无需逐个修改。
**Evidence**: CatSpriteTabNameTests.swift 中 4 处硬编码 fontSize==9 和 fontSize==11，常量改为 12/14 后 6 个测试失败。修复后使用 CatConstants.Visual.tabLabelFontSize 引用。

### [2026-04-13] SpriteKit moveBy 动画中断留下位置残留
<!-- tags: spritekit, animation, switchState, moveBy -->
**Scenario**: 在 CatSprite 的 `node`（子节点）上使用 `SKAction.moveBy` 做视觉动画（如小跳 Y+6px），期间 `switchState` 被调用
**Lesson**: `node.removeAllActions()` 只停止动画但不复位 `node.position`。`switchState` 的 transform 重置区域必须包含 `node.position.y = 0`，否则猫精灵会"浮"在地面上方。对 `node` 做相对位移动画时，永远在中断清理路径中复位位置。
**Evidence**: QA Tier 2b 代码质量审查发现 `playExcitedReaction` 的 hop 动画（moveBy y+6 / y-6）被中断后残留最大 +6px 偏移。修复：CatSprite.swift:301 添加 `node.position.y = 0`

### [2026-04-16] 垂直动画峰值由窗口高度和地面位置共同决定
<!-- tags: window, bounds, animation, jump, physics -->
**Scenario**: 为猫咪跳跃引入抛物线轨迹，初版未考虑窗口高度约束，导致猫咪飞出窗口被截断
**Lesson**: 添加或调整垂直动画（跳跃、弹跳、受惊反应）前，必须计算可用垂直空间：`窗口高度(DockTracker.buddyWindowFrame) - groundY(CatConstants.Visual.groundY) = 猫咪上方可用像素`。动画峰值应留有余量（如 80%），不超出此范围。窗口高度由 `DockTracker.buddyWindowFrame(height:)` 的默认参数决定，可被调用方覆盖，因此不要在知识中写死具体像素值。
**Evidence**: 初版跳跃峰值 60-130px 远超 80px 窗口中 groundY=48 上方的 32px 可用空间，用户验收时发现截断

### [2026-04-13] AX API 查询 + 启发式回退
<!-- tags: accessibility, dock, ax-api, fallback -->
**Scenario**: 需要获取 macOS Dock 图标区域的精确像素边界来限制猫咪活动范围
**Lesson**: `DockIconBoundsProvider` 先尝试 AX API（`AXUIElementCreateApplication` → `kAXChildrenAttribute` → 找 `AXList` → 读 position/size），失败时回退到启发式估算（屏幕中央 ~60%）。AX API 必须在主线程调用。Timer 轮询 3s 间隔 + NSWorkspace 通知检测 Dock 变化。
**Evidence**: DockIconBoundsProvider.swift, AppDelegate.swift 的 `setupDockMonitoring()` 方法

### [2026-04-13] SPM library target 的 Bundle.module 在 .app 打包中的正确路径
<!-- tags: spm, bundle, resource, packaging, crash -->
**Scenario**: Swift Package 的 library target（BuddyCore）声明了 `.copy("Assets")` 资源，executable target 依赖该 library。`swift build` 生成 `ClaudeCodeBuddy_BuddyCore.bundle`，但打包脚本未将其放入 .app 导致启动 crash。
**Lesson**: SPM 生成的 `resource_bundle_accessor.swift` 查找路径为 `Bundle.main.bundleURL.appendingPathComponent("ClaudeCodeBuddy_BuddyCore.bundle")`。对 macOS .app 而言，`Bundle.main.bundleURL` 指向 `.app` 根目录，因此资源 bundle 必须复制到 `.app/` 根目录下（与 `Contents/` 同级）。不要将原始 Assets 目录复制到 `Contents/Resources/`——那不是 Bundle.module 的查找路径。
**Evidence**: Scripts/bundle.sh 修复 commit 5898989; .build/release/BuddyCore.build/DerivedSources/resource_bundle_accessor.swift

### [2026-04-16] Plugin 缓存与源码不同步导致 hook 事件映射错误
<!-- tags: plugin, cache, hooks, debugging, event-mapping -->
**Scenario**: 源码 `plugin/scripts/buddy-hook.sh` 中 `"Stop"` 已映射为 `"task_complete"`，但 `~/.claude/plugins/cache/claude-code-buddy/...` 中的缓存版本仍是旧的 `"idle"` 映射，导致猫咪在 Claude Code 停止时从不走到右边床上睡觉。
**Lesson**: Claude Code plugin 系统从 `~/.claude/plugins/cache/` 读取 hook 脚本执行，不会自动检测源码变更。修改 hook 脚本后必须手动同步到三个位置：(1) `plugin/scripts/buddy-hook.sh`（源码）(2) `hooks/buddy-hook.sh`（本地副本）(3) `~/.claude/plugins/cache/...`（运行时缓存）。当 hook 行为不符合预期时，首先 diff 缓存与源码版本。
**Evidence**: 用户报告 Stop 事件从未触发 taskComplete 状态，排查发现缓存脚本第 58 行 `"Stop": "idle"` 与源码 `"Stop": "task_complete"` 不一致

### [2026-04-14] .app 内嵌 CLI 工具通过 Homebrew cask binary 指令暴露到 PATH
<!-- tags: homebrew, cask, cli, packaging, distribution -->
**Scenario**: 需要将 .app bundle 内的 CLI 工具暴露到用户 PATH
**Lesson**: Homebrew cask 支持 `binary` 指令，自动从 .app 内部创建 symlink 到 Homebrew bin 目录（自动适配 `/opt/homebrew/bin` 或 `/usr/local/bin`）。无需 post_install 脚本或手动 symlink。格式：`binary "#{appdir}/AppName.app/Contents/MacOS/cli-binary"`。zap 清理自动处理。
**Evidence**: homebrew/Casks/claude-code-buddy.rb 的 binary 指令

### [2026-04-16] Unix socket write 必须循环处理部分写入
<!-- tags: socket, posix, networking, write, partial-write -->
**Scenario**: 通过 Unix domain socket 向客户端发送 JSON 响应
**Lesson**: `Darwin.write()` 可能返回比请求更少的字节数（部分写入）。必须循环写入直到全部数据发送完毕或发生错误。单次 `write` 并不保证完整发送。这在本地 socket 上较少见但并非不可能（内核缓冲区满、信号中断等）。
**Evidence**: SocketServer.swift `sendResponse(data:to:)` 方法 — 从单次 write 改为 while 循环
