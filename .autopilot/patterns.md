# Patterns & Lessons

### [2026-04-26] smoothTurn 动画与即时位移并发导致猫咪反向行走
<!-- tags: spritekit, animation, facing, movement, smoothturn, xscale -->
**Scenario**: `doRandomWalkStep()` 调用 `face(towardX:)` 触发 `smoothTurn`（0.2s 渐进 xScale 插值），但 `moveTo` 位移立即开始。0.2s 窗口内猫身体朝旧方向但脚往新方向跑。`walkStartSlowFactor` 放慢前两帧使不一致更明显。
**Lesson**: `smoothTurn` 适合状态转换等不涉及即时位移的场景。走路方向切换时必须 snap（取消 smoothTurn + 即时设置 xScale），因为 `moveTo` 在 containerNode 上立即生效，与 node 上的渐进动画存在不可调和的时序竞争。修复模式：`face(towardX:)` 后检查 `node.action(forKey: "smoothTurn") != nil`，若存在则 `removeAction` + `applyFacingDirection(animated: false)`。
**Evidence**: 用户报告猫咪反着跑。分析发现 smoothTurn(0.2s) 在 node 上插值 xScale，同时 moveTo 在 containerNode 上位移，两者并发。新增 `testRandomWalkFacingMatchesDirection` 验证 xScale 在走路时必须为 ±1.0。
**Recurrence [2026-04-26]**: `walkToFood()` 和 `walkBackIntoBounds()` 遗漏了同样的 snap 模式。`walkToFood` 中 `face()` 启动 smoothTurn 后 `node.removeAllActions()` 杀死它但未 snap xScale，导致间歇性反着跑（仅当猫背对食物时触发）。**通用规则**：任何调用 `face()` 后接 `removeAllActions()` 的路径，必须紧跟 `applyFacingDirection()` snap。审查清单：grep `removeAllActions` + 检查前后是否有 `face()` 调用。

### [2026-04-26] switchState 渐进式 Handoff 需要 display link 降级路径
<!-- tags: spritekit, state-machine, transition, testing, display-link -->
**Scenario**: `switchState()` 从即时 `removeAllActions()` 改为 0.15s handoff 窗口（加速旧动画 → dispatch 清理 → 进入新状态），但测试环境无 display link，SKAction 不执行，`isTransitioningOut` 永远为 true。
**Lesson**: 任何依赖 SKAction 时序的行为逻辑，必须检查 `containerNode.scene?.view != nil`（display link 可用性），不可用时回退到即时路径。这与 `smoothTurn` 的降级模式一致（patterns.md [2026-04-23]）。通用规则：SKAction 是视觉增强手段，不是逻辑保证——逻辑路径必须有不依赖 SKAction 的 fallback。
**Evidence**: 测试中 `switchState` 的 dispatch SKAction 从不执行，`isTransitioningOut` 保持 true，后续所有 switchState 调用被队列吞噬。添加 `hasDisplayLink` 检查后走即时路径，427 测试全部通过。

### [2026-04-20] SpriteKit 标签阴影常量命名与用法不一致导致阴影错位
<!-- tags: spritekit, labels, shadow, constants, position -->
**Scenario**: `labelShadowOffset` 命名暗示相对偏移量，但代码中作为 `shadow.position` 的绝对坐标使用。值 `(1.5, 1.5)` 将阴影放到了精灵脚部而非主标签附近，在 permissionRequest 状态同时显示时导致文字重复。
**Lesson**: 当 SpriteKit 常量名含 "offset" 时，确认是相对偏移还是绝对位置。Tab name shadow 使用独立的 `tabLabelShadowYOffset` 绝对坐标是正确模式。阴影节点应与主节点的 Y 坐标保持 1px 差距（如 main Y=28, shadow Y=27）。检查方法：grep 所有 `.position = .*Offset` 确认语义一致。
**Evidence**: `labelShadowOffset = (1.5, 1.5)` → shadow 在 Y=1.5，main label 在 Y=28，肉眼可见两行重复文字。改为 `(1.5, 27)` 后视觉正确。

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

### [2026-04-18] 中文标签间距需比拉丁字符预估值大 ~2 倍
<!-- tags: spritekit, labels, spacing, cjk, font-size -->
**Scenario**: 猫屋 bed slot 间距 -56px，改为 -80px 后中文标签仍重叠，最终需 -100px
**Lesson**: 12pt 中文字符宽度约 12-14px/字，比拉丁字符（~7px/字）宽近 2 倍。估算中文标签所需间距时，不能按拉丁字符的 charWidth 预估——应以实际中文标签长度（字数 × 13px + padding）为基准，并留 20% 余量。对于 4-6 个中文字符的标签，100px 间距是安全下限。
**Evidence**: slotSpacing -56 → -80 用户反馈仍重叠 → -100 通过验收

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

### [2026-04-19] 外部 sprite sheet → 皮肤包的处理流水线
<!-- tags: skin, sprite-sheet, pillow, upload, manifest, skin-pack -->
**Scenario**: 从外部像素艺术素材（横向 sprite sheet）制作皮肤包并上传到皮肤商店
**Lesson**: 处理流水线为：(1) 按帧宽切割 sprite sheet 为单帧 (2) 对每帧 auto-trim 透明边距（`Image.getbbox()` + `crop()`）(3) 等比缩放适配目标画布（高度优先，`Image.NEAREST` 保持像素锐利）(4) 粘贴到目标画布上底部居中对齐（角色脚在底边，匹配 app 的 groundY 定位）。Manifest 校验要求：`food_names` 和 `bed_names` 必须是非空数组（空数组会被 CLI 和服务端拒绝）；CLI 本地检查 key sprite `<prefix>-idle-a-1.png` 存在；`canvas_size` 必须与实际 PNG 尺寸匹配。9 个必需动画名：idle-a/idle-b/clean/sleep/scared/paw/walk-a/walk-b/jump。Menubar 精灵需单独缩放到 ~50×34。
**Evidence**: pixel-knight 皮肤包制作——96×84 Knight sprite sheet → 48×48 画布，Python Pillow 处理 55 帧 + 12 menubar 帧，CLI 上传成功

### [2026-04-16] CatEatingState 未实现 ResumableState，热替换需特殊处理
<!-- tags: spritekit, state-machine, hotswap, eating, resumable -->
**Scenario**: 设计皮肤热替换机制时，计划对所有活跃猫调用 `(stateMachine.currentState as? ResumableState)?.resume()` 重启动画
**Lesson**: 6 个 GKState 中，CatEatingState 是唯一不实现 ResumableState 的状态。热替换（或任何需要 `resume()` 的机制）必须对 eating 状态做特殊处理：跳过 resume，让 eating 动画自然完成，完成后的 `switchState(to: .idle)` 会自动使用新纹理。在 `reloadSkin()` 中需要先 `node.removeAllActions()` 清理旧动画帧引用，再 `loadTextures()`，最后才 `resume()`——顺序不能错。
**Evidence**: Plan Review 发现 CatEatingState.swift:4 仅 `final class CatEatingState: GKState`，无 ResumableState 协议。Grep 确认 5 个状态实现 ResumableState，eating 缺席。

### [2026-04-19] LSUIElement app 中 NSCollectionView 选择机制不工作
<!-- tags: appkit, lsuielement, nscollectionview, key-window, nswindow, click -->
**Scenario**: 皮肤市场 Settings 面板用 NSCollectionView + isSelectable=true 实现皮肤选择，单击无反应，双击才响应
**Lesson**: LSUIElement=true 的 menubar agent app 无法可靠激活（NSApp.isActive 始终 false），因此其窗口无法成为 key window。NSCollectionView 的 didSelectItemsAt 依赖 key window，在 LSUIElement app 中完全失效。尝试过的无效方案：NSClickGestureRecognizer（不可靠）、mouseUp override（第一次点击被窗口激活消耗）、acceptsFirstMouse（无效）、makeKey()（app 未激活时无效）、NSApp.activate()（LSUIElement 下不生效）。正确方案：在 NSPanel 子类的 sendEvent(_:) 中拦截 mouseUp，通过 collectionView.indexPathForItem(at:) 坐标计算找到目标 item，直接调用回调。sendEvent 是最底层且 100% 可靠的事件入口，不依赖 key window 状态。
**Evidence**: 诊断日志显示 appActive=false + isKeyWindow=false 贯穿所有点击事件。修改为 sendEvent 拦截后单击 100% 响应。

### [2026-04-19] 第三方精灵图朝向需在 manifest 中声明
<!-- tags: skin, sprite, facing, manifest, third-party -->
**Scenario**: 上传像素狗皮肤包后，狗跑步方向反转——狗精灵面朝左，而 app 假设精灵面朝右
**Lesson**: SpriteKit 中通过 xScale 翻转实现角色转向，默认假设精灵面朝右 (xScale=1.0=面右)。第三方皮肤的精灵朝向不确定，需在 manifest 中声明 `sprite_faces_right: bool`。app 端 CatSprite.applyFacingDirection() 读取此字段，当 sprite 面朝左时反转 xScale 逻辑：`xScale = (facingRight == spriteFacesRight) ? 1.0 : -1.0`。CLI 上传工具通过 `--facing left|right` 参数自动写入 manifest。
**Evidence**: 用户验证像素狗走路方向反转。添加 sprite_faces_right=false 后方向正确。

### [2026-04-18] release.yml 与 bundle.sh 打包步骤不同步导致 CI 产物缺资源
<!-- tags: ci, release, packaging, bundle, icon, if-guard, integrity-check -->
**Scenario**: 本地 `make bundle`（调用 Scripts/bundle.sh）打包的 .app 有 icon，但 GitHub CI release.yml 打包的 .app 缺少 icon
**Lesson**: 项目有两条独立的 .app bundle 组装路径：`Scripts/bundle.sh`（本地）和 `.github/workflows/release.yml`（CI）。新增 bundle 内容（如资源文件、新的可执行文件）时，必须在两处同时添加 cp 步骤。排查"本地有 CI 没有"问题时，优先 diff 这两个文件。同类陷阱：plugin 缓存与源码不同步（见上方条目）。
**防御措施（2026-04-19 补充）**:
1. 打包脚本中对必要文件使用 bare `cp`（不要 `if [ -f ]; then cp; fi`）。`set -euo pipefail` + bare cp = 文件缺失时立即报错退出；`if` 保护会静默跳过，掩盖打包遗漏。
2. release.yml 的 "Verify bundle integrity" 步骤在 codesign 前检查 5 个必要文件（executable、CLI、Info.plist、AppIcon.icns、SPM resource bundle），作为第二道防线。
**Evidence**: bundle.sh:40-43 有 `cp AppIcon.icns`，release.yml:47-68 缺少该步骤。CI 产出的 .app 在 Finder 中显示通用白纸图标。修复后 bundle.sh 移除 if 保护 + release.yml 添加 integrity check。

### [2026-04-19] 精灵图 alpha 帧检测被粒子/特效残留误导
<!-- tags: skin, sprite, slicing, alpha, frame-detection -->
**Scenario**: 用 alpha 扫描（任意像素 alpha>10 即为有内容）自动检测精灵图每行帧数时，死亡/消散动画行的粒子残留被误判为有效帧
**Lesson**: 纯 alpha 检测适合角色动画行，但对含 VFX（粒子、爆炸、光效）的行会过度计数。切片精灵图时，对已知有特效的行应设置 `max_frames` 上限，并在切片后目视验证末尾帧。另一方案是改用最小像素数阈值（如非透明像素 >50 才算有效帧），但手动 max_frames 更精准。
**Evidence**: Satyr 精灵图 row 6（死亡动画）alpha 扫描检测到 10 帧，但帧 5+ 只有零星粒子点（jump-9.png/jump-10.png 几乎全透明）。添加 `"max_frames": 4` 后修复。

### [2026-04-21] switchState same-state guard 阻止拖拽后状态恢复
<!-- tags: spritekit, state-machine, drag, same-state, restore -->
**Scenario**: 拖拽猫咪时不改变 GKStateMachine 的 currentState，松手后 restoreState 调用 switchState(to: preState)，但 preState == currentState 触发 same-state guard 直接 return，导致动画不恢复、taskComplete 猫不回猫屋。
**Lesson**: GKStateMachine 的 same-state guard 会阻止任何"恢复到当前状态"的尝试。当某个机制（拖拽、暂停等）需要在不改变 GKState 的情况下中断并恢复时，恢复逻辑必须绕过 same-state guard：先 switchState(.idle) 强制触发 willExit/didEnter 生命周期，再 switchState(targetState)。对于简单状态（idle/thinking/toolUse）也可用 ResumableState.resume()，但 taskComplete 等需要完整 didEnter 流程（请求床位、走路）的状态必须走强制重入。
**Evidence**: 拖拽 taskComplete 猫松手后不回猫屋。修复：restoreState 检测 targetState == currentState 时先 switchState(.idle) 再切回。

### [2026-04-23] smoothTurn 必须检查 display link 可用性
<!-- tags: spritekit, animation, skaction, testing, display-link -->
**Scenario**: `smoothTurn` 使用 `SKAction.customAction(withDuration:actionBlock:)` 渐进改变 xScale 实现方向翻转，但测试环境无 display link，SKAction 从不执行，导致 xScale 永远不变、测试失败。
**Lesson**: SKAction 的执行依赖 `SKView.displayLink` 驱动 `update(_:for:)` 回调。测试环境（无 scene/view）中 `node.run(action)` 会入队但不执行。任何基于 SKAction 的视觉增强必须检查 `containerNode.scene?.view != nil`，不可用时回退到即时赋值。同理，`SKAction.waitForDuration` 在无 display link 时也永远不完成。
**Evidence**: FacingDirectionTests 5 个测试失败——smoothTurn 的 customAction 从不触发 actionBlock，xScale 保持初始值。添加 `let hasDisplayLink = containerNode.scene?.view != nil` 检查后回退到 instant xScale。

### [2026-04-23] SwiftLint large_tuple 用内部结构体替代多元组返回
<!-- tags: swiftlint, tuples, struct, code-quality -->
**Scenario**: `CatPersonality.modifiedIdleWeights()` 返回 4 元素命名元组 `(sleep: Float, breathe: Float, blink: Float, clean: Float)`，SwiftLint 报 `large_tuple` 违规（>3 元素）。
**Lesson**: SwiftLint `large_tuple` 规则限制元组元素不超过 3 个。返回 4+ 值时，在类型内部定义 `struct IdleWeights { let sleep, breathe, blink, clean: Float }` 替代元组。结构体有命名参数、可扩展、不触发 lint 违规，且调用方代码几乎不变（`.sleep` vs `.0`）。
**Evidence**: CatPersonality.swift 从 `func modifiedIdleWeights(...) -> (sleep: Float, breathe: Float, blink: Float, clean: Float)` 改为返回 `IdleWeights` 结构体，lint 违规消失。

### [2026-04-26] Ghostty AppleScript `front window` 在多 tab 时捕获错误的 terminal ID
<!-- tags: ghostty, applescript, terminal, tab, hook, cwd -->
**Scenario**: hook 脚本用 `selected tab of front window` 捕获 Ghostty terminal ID 并缓存。多 tab 场景下，所有 session 可能都缓存了同一个（错误的）tab 的 ID，导致点击猫咪总是跳到第一个 tab。
**Lesson**: `front window` / `selected tab` 只返回当前用户聚焦的 tab，不是 Claude Code 运行所在的 tab。正确做法是遍历 `terminals of every tab of every window` 按 `working directory` 匹配（与 tab title 注入使用相同模式）。保留 `front window` 作为 CWD 匹配失败时的 fallback。同 CWD 多 tab 时匹配第一个，可接受但非完美。
**Evidence**: 3 个 Ghostty tab 分别运行不同 CWD 的 session，修复前全部缓存了 tab 1 的 terminal ID；修复后 CWD 匹配分别拿到了 3 个不同的正确 terminal ID。

### [2026-04-21] ignoresMouseEvents 在拖拽后未恢复导致窗口拦截点击
<!-- tags: appkit, window, mouse-events, drag, click-through -->
**Scenario**: BuddyWindow 默认 ignoresMouseEvents=true（点击穿透），hover 时切为 false。拖拽结束后 MouseTracker 的 isDragging 置 false 但没有恢复 ignoresMouseEvents=true，导致整个窗口持续拦截鼠标事件，用户无法点击窗口后面的应用。
**Lesson**: 任何修改 ignoresMouseEvents 的代码路径，必须有配对的恢复逻辑。拖拽结束（mouseUp）时应立即恢复 ignoresMouseEvents=true 并清除 hover 状态。落体+弹跳动画完全由 SKAction 驱动，不需要鼠标事件。通用规则：临时打开 mouse event 接收后，确认每个退出路径（正常结束、app 失焦、取消）都会恢复 click-through。
**Evidence**: 用户报告拖拽松手后无法点击其他窗口。mouseUp 中添加 `window?.setInteractive(false)` + `hoveredSessionId = nil` 后修复。
