<!-- tags: keyboardshortcuts, upgrade-migration, userdefaults, hotkey, launcher, carbon, registerhotkey, ad-hoc, sindresorhus, version-compat, reset-vs-nil -->
# KeyboardShortcuts 库升级后旧 UserDefaults 值与新库不兼容致全局热键失效

## 现象
buddy 升级 0.18.0→0.30.0（KeyboardShortcuts 库跨大版本到 2.4.0）后，全局热键（⌘⇧Space）注册成功（Carbon `RegisterEventHotKey` 返回 noErr + ref 非 nil）但**回调不触发**，用户按热键无反应。

## 根因（实测确认，非推测）
UserDefaults `KeyboardShortcuts_launcher-toggle` 的旧值（0.18.0 库写入）与 2.4.0 库反序列化格式不兼容 —— 库读到旧值后注册了热键但内部状态错误，回调链断裂。
- **诊断关键**：写最小裸 Carbon `RegisterEventHotKey` 测试 app 注册同款 ⌘⇧Space + 对照键 ⌘⇧P，**两个都能正常触发** → 铁证锁定"系统级正常，病根在 app 侧库存储" → 删旧 UserDefaults 值让库用 default 重注册 → 修复。
- 不是 TCC/辅助功能权限/进程崩溃/系统热键占用（这些都被 symbolichotkeys + 崩溃日志 + 进程检查 + 裸 Carbon 测试逐一排除）。

## Choice（修复）
启动迁移标志 `launcher.hotkeyMigrationV1`：`LauncherManager.setup` 中若标志未置，`UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_launcher-toggle")`（让库用新 default 重注册）+ 置标志。幂等（标志已置跳过，不清理用户自定义）。

## 陷阱
- `KeyboardShortcuts.setShortcut(nil)` 是**清除**快捷键（即使 Name 有 defaultShortcut），**非**回 default —— 回 default 必须 `KeyboardShortcuts.reset(.toggle)`（内部 `setShortcut(name.defaultShortcut, for:)`）。
- 跨大版本升级第三方库时，检查其 UserDefaults/持久化值的向后兼容；不兼容则一次性迁移清理 + 幂等标志。
- ad-hoc 签名 app 的 Carbon 全局热键**不需要** TCC 辅助功能权限（实测 macOS 26.4 正常），不要误判为权限问题。
- 旧值"看起来对"（`{carbonModifiers:768,carbonKeyCode:49}` = ⌘⇧Space）≠ 库能正确解析；JSON key 顺序/编码细节跨版本可能变。

## 何时复用
任何用 sindresorhus/KeyboardShortcuts 且跨版本升级的 app；任何"全局热键注册成功但不触发"的诊断 —— 先写裸 Carbon `RegisterEventHotKey` 测试 app 隔离"系统级 vs app 侧库存储"，再下结论。相关：[[buddycli-inline-subcommand-no-buddycore-dep]]（CLI 改键走 socket 而非直写库 UserDefaults，正是为了避免此类格式耦合）。
