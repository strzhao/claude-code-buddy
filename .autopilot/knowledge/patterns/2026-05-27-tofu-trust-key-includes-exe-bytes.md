# TOFU trustKey 必须包含 executable bytes hash，cmd+args 不足以防替换攻击

<!-- tags: tofu, trust, security, sha256, executable-hash, code-signing, plugin-system, supply-chain, trustkey, cryptokit, replay-attack, code-replacement -->

## 上下文

CLI 插件系统使用 TOFU（Trust On First Use）策略：首次执行弹框，用户允许后写入 `~/.buddy/launcher-trust.json` 记录信任。后续执行通过 trustKey 比对决定是否复用信任。

朴素实现只对 manifest 元数据（cmd + args）计算 trustKey：

```swift
// 错误：仅 cmd + args
let combined = "\(plugin.cmd)\n\(plugin.args.joined(separator: "\n"))"
let key = SHA256.hash(data: Data(combined.utf8)).hex()
```

## 攻击场景

用户允许 `./hello.sh` 执行 → trust.json 记录 trustKey-A。攻击者通过 `git pull` 推送更新，把 hello.sh 内容换成 `rm -rf ~`。manifest 的 cmd/args 不变 → trustKey-A 不变 → 用户无感执行恶意代码。

或 user/repo 仓库本身被 hijack，攻击者仅改 executable bytes 而不改 plugin.json 元数据。

## 解决

trustKey 把 executable 文件内容 hash 也纳入：

```swift
static func trustKey(for plugin: PluginManifest, executablePath: URL) throws -> String {
    let cmdPart = plugin.cmd
    let argsPart = plugin.args.joined(separator: "\n")
    let exeData = try Data(contentsOf: executablePath)
    let exeHash = SHA256.hash(data: exeData).hex()
    let combined = "\(cmdPart)\n\(argsPart)\n\(exeHash)"
    return SHA256.hash(data: Data(combined.utf8)).hex()
}
```

任一改动（cmd / args / executable bytes）→ trustKey 不同 → isTrusted 返回 false → 重新弹 NSAlert。

## 取舍

- **Pro**: 防供应链替换攻击。用户重新审阅修改后的命令再决定是否允许
- **Con**: 每次 `git pull` 升级插件都会重新弹框，UX 略噪
- **Mitigation**: v2 可考虑允许"信任此 repo 的未来版本"选项（但 MVP 不做）

## 验证

测试覆盖 SC-03（cmd/args/exe 三个变量任一改动 trustKey 变化）+ SC-10（红队 Python3 跨语言独立复现算法一致）。

## 关联

- [[plugin-manifest-security-validation]] CLI 插件 manifest 字段校验
- [[swift-process-orphan-pipe-deadlock]] Plugin Executor 子进程执行
