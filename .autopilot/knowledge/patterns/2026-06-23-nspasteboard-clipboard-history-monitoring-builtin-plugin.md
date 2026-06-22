# NSPasteboard 剪贴板历史：常驻 Timer 轮询 changeCount + 多类型优先级 + Concealed 排除 + writeObjects 回填坑

<!-- tags: nspasteboard, clipboard-history, timer, polling, changecount, concealed, transient, security, writeobjects, file-url, copy-service, builtin-plugin, paste, dedup, sha256, monitoring, macos, appkit, mainactor -->

**Scenario**: 新增 PastePlugin（BuiltinPlugin 第四个，priority=150）实现剪贴板历史。需常驻监听系统剪贴板变化（用户每次复制都记录），Launcher 输入 cb 召唤历史，选中回填。

**Lesson**:

1. **NSPasteboard 无可靠 change 通知**——必须 Timer 轮询 `pasteboard.changeCount`（行业标准，Alfred/Maccy 同款）。0.5s 间隔平衡实时性与功耗。启动时记录当前 changeCount，避免回灌旧内容：
   ```swift
   @MainActor final class ClipboardHistoryService {
       private var lastChangeCount = 0
       private var timer: Timer?
       func startMonitoring() {
           guard timer == nil else { return }  // 幂等
           load(); purgeExpired()
           lastChangeCount = pasteboard.changeCount
           timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
               MainActor.assumeIsolated { self?.tick() }  // @MainActor service 的 Timer 闭包需 assumeIsolated 进入
           }
       }
       private func tick() {
           let current = pasteboard.changeCount
           guard current != lastChangeCount else { return }
           lastChangeCount = current
           readPasteboard()
       }
   }
   ```

2. **多类型读取优先级 file > image > html > text**——file 最强，否则复制文件时只拿到文件名字符串：
   ```swift
   func readPasteboard() {
       if isConcealedOrTransient() { return }  // 安全排除在最前
       if let item = readFileURL() { append(item); return }   // public.file-url
       if let item = readImage() { append(item); return }     // public.png / tiff→png
       if let item = readHTML() { append(item); return }      // public.html + .string fallback
       if let item = readText() { append(item); return }
   }
   ```

3. **安全排除（硬约束，不可商量）**：`org.nspasteboard.ConcealedType`（密码管理器、1Password）+ `org.nspasteboard.TransientType`（临时）必须排除，否则记录密码造成泄露：
   ```swift
   private func isConcealedOrTransient() -> Bool {
       let types = pasteboard.types ?? []
       return types.contains(.init(rawValue: "org.nspasteboard.ConcealedType"))
           || types.contains(.init(rawValue: "org.nspasteboard.TransientType"))
   }
   ```

4. **回填循环化解**：perform 回填写剪贴板 → changeCount++ → Timer 检测 → sha256 命中已有条目 → 提至队首不新增（去重策略保证不产生重复）。

5. **⚠️ CopyService 写文件路径必须 `writeObjects([NSURL])`，禁用 `setString(forType:.fileURL)`**——Finder/Spotlight 不认后者，用户粘贴到 Finder 无效（plan-reviewer 抓到）：
   ```swift
   func copyFileURL(_ url: URL) {
       pasteboard.clearContents()
       pasteboard.writeObjects([url as NSURL])  // ✅ Finder 认
       // pasteboard.setString(url.absoluteString, forType: .fileURL)  // ❌ Finder 不认
   }
   ```

**Rationale**: 剪贴板历史是 Alfred/Maccy/Raycast 的标准原生功能，落地 [[launcher-builtin-plugin-direct-action-pipeline]] decision 点名的「剪贴板」BuiltinPlugin。常驻监听必须在 app 进程（插件是非常驻子进程，监听不了），交互层走 BuiltinPlugin（in-process 直驱，零延迟、天然绕过 LLM、无 command 模式 provider bypass 坑）。

**Evidence**: PastePlugin 落地于 `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Paste/`，蓝队单测 46 + 红队 acceptance 38 = 84 tests 全绿（含 scenario8 端到端 Timer 监听验证）。writeObjects 坑由 plan-reviewer 发现并固化进 `CopyService.copyFileURL`。富文本回填用 `public.html` + 纯文本双写（不转 RTF，YAGNI）。

**关联**: [[nspasteboard-test-isolation-via-named-pasteboard]]（测试用 NSPasteboard(name:) 隔离）、[[launcher-builtin-plugin-direct-action-pipeline]]（BuiltinPlugin 协议 decision，点名剪贴板）、[[appdelegate-mainactor-assumeisolated-setup]]（@MainActor Timer 闭包 assumeIsolated）、[[ghostty-applescript-tcc-second-layer]]（回填不模拟 ⌘V 避开 TCC）
