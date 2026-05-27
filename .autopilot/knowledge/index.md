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
- [2026-05-04] macOS 非沙盒 app 的 Apple Events TCC 权限仅需 NSAppleEventsUsageDescription | tags: macos, tcc, apple-events, applescript, permission, infoplist, codesign | → patterns.md
- [2026-05-04] Ghostty AppleScript 模式补充 — -1743 权限错误是独立于 terminal ID 缓存的第二层问题 | tags: ghostty, applescript, terminal, tab, tcc, permission | → patterns.md
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

## 2026-05-25 新增条目
- [2026-05-25] 跨技术栈 monorepo 用 pnpm workspace + apps/* + packages/* 拓扑 | tags: monorepo, pnpm-workspace, swift, nextjs, cli, architecture | → decisions.md
- [2026-05-25] softprops/action-gh-release 的 files: 字段路径解析基于 GITHUB_WORKSPACE 而非 step working-directory | tags: github-actions, release, working-directory, glob, softprops, files, monorepo | → patterns.md
- [2026-05-25] macOS 案例不敏感 FS 让 git mv Tests/ 与 git mv tests/ 在 tree 中合并为单一目录 | tags: macos, git-mv, case-insensitive, monorepo, refactor, apfs, tests | → patterns.md
- [2026-05-25] pnpm workspace 内部包的 bin 不会自动暴露给根 pnpm exec，需声明为 root workspace 依赖 | tags: pnpm, workspace, bin, exec, monorepo, devDependency | → patterns.md
- [2026-05-25] lint-staged 给 tsc 追加文件参数会绕过 tsconfig.json，用函数形式忽略文件列表 | tags: lint-staged, tsc, tsconfig, hook, pre-commit, husky, tsconfig-bypass | → patterns.md

## 2026-05-26 新增条目
- [2026-05-26] LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate | tags: nspanel, lsuielement, launcher, alfred, key-window, floating-window, swiftui, appkit, nshostingcontroller | → patterns.md
- [2026-05-26] NSPanel hidesOnDeactivate 与 didResignKeyNotification 双触发的 Combine 重入防御 | tags: nspanel, combine, published, reentrancy, hidesondeactivate, didresignkey, race-condition | → patterns.md
- [2026-05-26] AppDelegate.applicationDidFinishLaunching 调 @MainActor 单例 setup 用 MainActor.assumeIsolated | tags: mainactor, swift-concurrency, appdelegate, isolated, assumeisolated, async, applicationdidfinishlaunching | → patterns.md
- [2026-05-26] LSUIElement app + ad-hoc 签名下 Keychain 不可用，必须 SecretStore 探针降级到 CryptoKit | tags: keychain, ad-hoc, codesign, lsuielement, entitlement, secret-store, cryptokit, chachapoly, fallback, errSecMissingEntitlement | → patterns.md
- [2026-05-26] BuddyCLI 扩展配置子命令用 nested switch 内联实现，不加 BuddyCore 依赖避免拉入 GUI 框架 | tags: buddy-cli, swift-package-manager, target-dependency, nested-switch, cli-design, source-of-truth, command-line, lsuielement, cold-start | → patterns.md
- [2026-05-26] URLSession + URLProtocol mock 必须读 httpBodyStream 回 httpBody | tags: urlsession, urlprotocol, mock, http-body, http-body-stream, network-mock, swift-testing, canonical-request | → patterns.md
- [2026-05-26] 跨任务红队契约演进：上游 task 锁的过渡占位需迁移而非保留 XCTSkip | tags: red-team, acceptance-test, contract-evolution, cross-task, tdd, autopilot, brief-mode | → patterns.md
- [2026-05-26] AsyncStream + Task.detached + onTermination cancel 双层取消传播链 | tags: async-stream, task-detached, on-termination, cancel, swift-concurrency, streaming, asyncsequence, structured-concurrency, leak-prevention | → patterns.md
- [2026-05-26] @MainActor 类内异步方法用同步前置读 + Task.detached 离开 actor 隔离避免阻塞 UI | tags: mainactor, task-detached, actor-isolation, ui-blocking, async-await, sendable, capture-list, swift-concurrency | → patterns.md
- [2026-05-26] 自定义 Equatable 的 mutation 探针陷阱：toolCall.== 必须比较所有携带状态 | tags: equatable, mutation-testing, false-positive, swift-enum, associated-values, anycodable, red-team, acceptance-test, tdd, plan-reviewer | → patterns.md
- [2026-05-26] Swift Process API 子进程 SIGKILL 后 orphan child 持 pipe 写端导致 readDataToEndOfFile 无限死锁 | tags: process, subprocess, sigkill, orphan-child, pipe, file-handle, deadlock, readabilityhandler, readdatatoendoffile, swift-concurrency, plugin-runtime | → patterns.md
- [2026-05-26] SPM .copy 把可执行脚本打入 bundle，拷贝后必须显式 chmod 0o755 | tags: spm, swift-package-manager, copy, bundle-resource, hello-plugin, chmod, posix-permissions, resource-only-read, app-signing, lsuielement | → patterns.md
- [2026-05-26] CLI 插件 manifest 字段校验防恶意：name 与 dirName 一致 + cmd 不允许绝对路径或 /.. | tags: plugin, manifest, security, path-traversal, malicious, validation, name-collision, code-execution | → patterns.md
- [2026-05-27] AI 路由器 system prompt 拼 user message 前缀 + 强约束输出 — provider 协议无 system 字段的稳健替代 | tags: ai-router, system-prompt, llm-routing, user-message-prefix, plugin-selection, anthropic, structured-output, hallucinate-fallback, provider-abstraction | → patterns.md
- [2026-05-27] NSHomeDirectory() 在 macOS 上忽略 HOME 环境变量，CLI 测试需显式读 $HOME | tags: nshomedirectory, macos, home-env, cli-testing, test-isolation, buddy-cli, getpwuid | → patterns/2026-05-27-nshomedirectory-ignores-home-env.md
- [2026-05-27] TOFU trustKey 必须包含 executable bytes hash，cmd+args 不足以防替换攻击 | tags: tofu, trust, security, sha256, executable-hash, plugin-system, supply-chain, trustkey, cryptokit | → patterns/2026-05-27-tofu-trust-key-includes-exe-bytes.md
