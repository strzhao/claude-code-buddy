# SPM .copy("Resources-Dir") 把可执行脚本打入 BuddyCore bundle，拷贝后必须显式 chmod 0o755

<!-- tags: spm, swift-package-manager, copy, bundle-resource, hello-plugin, chmod, posix-permissions, resource-only-read, app-signing, lsuielement -->
**Scenario**: task 004 在 BuddyCore target 加 `.copy("Plugins")` 把 bundled HelloPlugin 资源（含 `hello.sh` shell 脚本）打入 BuddyCore.bundle。runtime 启动时通过 `ResourceBundle.bundle.url(forResource:withExtension:subdirectory:)` 定位 + FileManager.copyItem 拷贝到 `~/.buddy/launcher-plugins/builtin-hello/`。问题：Bundle 内的 hello.sh **默认无执行权限**（SPM `.copy` 不保留源文件 posix 权限）。Process.run() 直接报 "permission denied" 启动失败。
**Lesson**: SPM bundled 可执行脚本资源**必须**在 install/copy 到目标目录后显式 setAttributes 加可执行位：
```swift
try FileManager.default.copyItem(at: sourceURL, to: targetURL)
let helloScript = targetURL.appending(path: "hello.sh")
if FileManager.default.fileExists(atPath: helloScript.path) {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helloScript.path)
}
```
**关于 Bundle.module**：项目 LSUIElement + ad-hoc 签名场景下，**优先用项目自定义 `ResourceBundle.bundle`**（位于 Sources/ClaudeCodeBuddy/ResourceBundle.swift），它先尝试 `Bundle.main.resourceURL.appending(path: "ClaudeCodeBuddy_BuddyCore.bundle")` 适配 .app 打包结构，再 fallback `Bundle.module`。直接 `Bundle.module` 在 .app 中失效（macOS 签名禁止 .app 根级文件）。
**Evidence**: task 004 PluginManager.installBundledPlugins 在 copyItem 后 setAttributes 0o755；PluginBundledHelloAcceptanceTests test_installBundledPlugins_helloShPermissions_755 精确断言 perms == 0o755；plan-reviewer 第 1 轮 BLOCKER-1 即 Bundle.module 失效问题，修复改用 ResourceBundle.bundle。
