# CLI 插件 manifest 字段校验防恶意：name 与 dirName 一致 + cmd 不允许绝对路径或 `/..`

<!-- tags: plugin, manifest, security, path-traversal, malicious, validation, name-collision, code-execution -->
**Scenario**: CLI 插件协议中 `plugin.json.cmd` 是子进程 executable 相对路径，`name` 是 plugin 标识。如果不做校验，恶意 plugin 可：① `cmd: "/usr/bin/rm"` 直接调用系统命令（绕过 plugin 沙箱意图） ② `cmd: "../../escape.sh"` 路径遍历到 plugin 目录外 ③ 把 `name: "trusted-plugin-name"` 写到任意目录名，绕过 trust check（TOFU 信任基于 name + 内容 hash）。
**Lesson**: `PluginManifest.validate(againstDirName:)` 强制 3 项规则：
1. **name 与 dirName 一致**：`name == dirName || name == dirName.split("-").last`（允许 `user-repo` 目录的 manifest name="repo" 简化命名）—— 防 manifest 把自己冒充成 trust 列表里的另一个 plugin
2. **cmd 必须相对路径**：`!cmd.hasPrefix("/")` —— 拒绝绝对路径
3. **cmd 不能含 `..`**：`!cmd.contains("/..")` 且 `!cmd.contains("../")` —— 防路径遍历到 plugin 目录外
配合 `currentDirectoryURL = pluginDir` 沙箱（Process 启动时 cwd 限定）+ `Process.arguments` 数组传参（不走 shell，无 command injection），三层防御。**关键**：每条规则在 validate() 拆为独立 guard + 独立错误消息（task 004 设计文档要求 5 反例独立测试），调试时能精确定位攻击向量。
**Evidence**: task 004 PluginManifest.swift validate 实现 3 项 guard；PluginManifestAcceptanceTests 5 反例覆盖（name 不匹配 / cmd 绝对路径 / cmd 含 .. / timeout 超出 / requiredPath > 10）+ 2 正例（name=="repo" dirName=="user-repo" / name==dirName）；qa-reviewer Section B OWASP A03/A01 评 PASS。
