<!-- tags: spm, bundle, resource, crash, keyboardshortcuts, recordercocoa, bundle-module, codesign, app-bundle, custom-replacement, hotkey, settings -->
# SPM 依赖库组件因 Bundle.module 找不到资源 bundle 崩溃：自定义替换策略

## 场景
`KeyboardShortcuts` 库的 `RecorderCocoa` 在 init 时访问 `Bundle.module`（SPM 自动生成的资源 bundle 访问器），其查找路径是 `.app/KeyboardShortcuts_KeyboardShortcuts.bundle`（Bundle.main.bundleURL 根目录）。但本地打包脚本 `bundle.sh` / `dev-bundle.sh` 未复制该 bundle，且 CI `release.yml` 虽复制到 `Contents/Resources/` 但与 `.app/` 根目录路径不匹配。结果：`fatalError("could not load resource bundle")` → SIGILL 崩溃。

## 根因链
1. SPM `resource_bundle_accessor.swift` 生成代码：`Bundle.main.bundleURL.appendingPathComponent("XXX.bundle")` — 查找路径 = `.app/` 根目录
2. codesign 拒绝 `.app/` 根目录有非标准内容（"unsealed contents present in the bundle root"），资源 bundle 只能放 `Contents/Resources/`
3. 路径冲突：SPM 查找 `.app/` 根目录，但 bundle 在 `Contents/Resources/` — 两路径不一致
4. `Bundle.module` 是 `static let` + `dispatch_once`，初始化失败无优雅降级，直接 `fatalError`
5. 对项目自身 library（BuddyCore）：`ResourceBundle.swift` 包装器先查 `Contents/Resources/` 再 fallback `Bundle.module` 可解。但对第三方依赖库（KeyboardShortcuts）：无法修改其 `Bundle.module` 初始化逻辑

## Choice（修复）
**用自定义实现替换依赖 Bundle.module 的第三方组件**：
- 阅读第三方库的 public API（`KeyboardShortcuts.setShortcut` / `getShortcut` / `reset` / `Shortcut.init(event:)`）
- 用纯 AppKit（`NSView` + `keyDown(with:)` + `NSClickGestureRecognizer`）实现等效 UI
- 直接调用库的 public API 而非依赖库的 UI 组件（`RecorderCocoa`）
- 不访问 `Bundle.module`，完全避开资源 bundle 查找问题

## 陷阱
- 第三方库的内部通知名可能为 `internal`（如 `KeyboardShortcuts.shortcutByNameDidChange`），需用字符串字面量 `Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")` 替代
- `Shortcut.description` 标注 `@MainActor`，需在 `MainActor` 上下文调用
- 自定义录制器需处理 `acceptsFirstResponder`、`becomeFirstResponder`/`resignFirstResponder` 状态切换、Escape 取消录制

## 防御性补充
即使自定义组件不再依赖 Bundle.module，**仍应补齐打包脚本**（`bundle.sh` / `dev-bundle.sh`）复制第三方库的资源 bundle 到 `Contents/Resources/`，防止库内其他路径未来访问 Bundle.module。

## 何时复用
任何 SPM 依赖库的 UI 组件初始化崩溃（`fatalError("could not load resource bundle")`），且该库提供足够 public API 允许自行实现等效功能时。相关：[[spm-bundle-module-app-package-path]]（SPM 资源 bundle 在 .app 中的路径问题）、[[appkit-contentviewcontroller-root-view-frame-fitting-size]]（设置面板 VC root view 模式）。
