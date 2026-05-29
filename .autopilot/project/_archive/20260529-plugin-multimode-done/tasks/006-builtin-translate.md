---
id: "006-builtin-translate"
depends_on: ["004-prompt-executor", "005-trust-mode-aware"]
complexity: M
acceptance_scenarios: [SC-1, SC-2, SC-3, SC-4, SC-10]
---

# Task 006: builtin-translate prompt plugin 部署 + 剪贴板复制 + inspect 显示 mode

## 目标

落地 `builtin-translate` prompt mode 插件：
1. 创建 `Sources/.../Plugins/TranslatePlugin/plugin.json`（无可执行文件）
2. `installBundledPlugins()` 扩展安装该插件，对 prompt mode 跳过 chmod
3. 翻译成功后自动复制译文到剪贴板，UI 显示 "(已复制到剪贴板)" 提示
4. `buddy launcher inspect` 输出 JSON 含 mode 字段
5. 端到端验证：召唤 → 输入 → 译文 + 剪贴板更新

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：已有 builtin-hello（stdin mode）作为 bundled plugin 安装模板
- 升级动机：本 task 是新协议的产品交付——首个 prompt mode plugin 给用户用
- 关键：chmod 必须 mode-aware（prompt 无 sh 文件，对不存在文件 setAttributes 会抛异常）

## 契约规约

### 上游依赖（已完成）

- **task 004**：PromptExecutor 可用，dispatcher.execute(prompt) 走通
- **task 005**：trust mode-aware，prompt manifest 安装时弹 NSAlert

### 新引入 contract

#### 1. builtin-translate plugin.json

文件路径：`Sources/ClaudeCodeBuddy/Plugins/TranslatePlugin/plugin.json`

```json
{
  "name": "builtin-translate",
  "version": "0.1.0",
  "description": "中英互译助手，自动检测语言方向",
  "keywords": ["翻译", "translate", "tr", "中英", "英中", "fy"],
  "timeout": 30,
  "mode": "prompt",
  "systemPrompt": "你是一个专业的中英互译助手。\n\n规则：\n1. 检测输入语言：含中文字符 → 译为英文；纯英文/拉丁字符 → 译为中文\n2. 输出仅包含译文本身，不要任何解释、引号、Markdown 格式\n3. 保留原文的换行结构与标点风格\n4. 对于专有名词、代码片段、URL，保持原样不译\n5. 译文风格：日常流畅，避免机械直译；商务/技术文本保持正式",
  "maxIterations": 1,
  "model": null
}
```

**目录**：`Sources/ClaudeCodeBuddy/Plugins/TranslatePlugin/`（与 HelloPlugin 同级）
**关键**：**目录内无任何可执行文件**（只有 plugin.json）

#### 2. installBundledPlugins() 扩展

`PluginManager.installBundledPlugins()` 当前对 HelloPlugin 做：
1. `ResourceBundle.bundle.url(forResource: "plugin", withExtension: "json", subdirectory: "HelloPlugin")` 找 plugin.json
2. `ResourceBundle.bundle.url(forResource: "hello", withExtension: "sh", subdirectory: "HelloPlugin")` 找 sh
3. FileManager.copyItem 到 `~/.buddy/launcher-plugins/builtin-hello/`
4. `chmod 0o755` sh 文件（patterns.md `[2026-05-26]` 陷阱）

扩展为 mode-aware：

```swift
private func installBundledPlugins() throws {
    try installBundledPlugin(name: "HelloPlugin", targetDir: "builtin-hello")
    try installBundledPlugin(name: "TranslatePlugin", targetDir: "builtin-translate")
}

private func installBundledPlugin(name bundleDir: String, targetDir: String) throws {
    let target = pluginsRoot.appendingPathComponent(targetDir)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    
    // 1. 拷贝 plugin.json
    guard let pluginJsonURL = ResourceBundle.bundle.url(
        forResource: "plugin", withExtension: "json", subdirectory: bundleDir
    ) else {
        throw LauncherError.bundledPluginNotFound(bundleDir)
    }
    try FileManager.default.copyItem(at: pluginJsonURL, to: target.appendingPathComponent("plugin.json"))
    
    // 2. 读 manifest 判断 mode
    let data = try Data(contentsOf: pluginJsonURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    
    // 3. mode 分支：仅 stdin 需要拷贝可执行文件 + chmod
    if case .stdin(let cfg) = manifest.modeConfig {
        let exeBaseName = (cfg.cmd as NSString).lastPathComponent
        let exeExt = (exeBaseName as NSString).pathExtension
        let exeResource = (exeBaseName as NSString).deletingPathExtension
        guard let exeURL = ResourceBundle.bundle.url(
            forResource: exeResource, withExtension: exeExt, subdirectory: bundleDir
        ) else {
            throw LauncherError.bundledPluginNotFound("\(bundleDir)/\(exeBaseName)")
        }
        let targetExe = target.appendingPathComponent(exeBaseName)
        try FileManager.default.copyItem(at: exeURL, to: targetExe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetExe.path)
    }
    // prompt mode: 跳过可执行文件拷贝 + chmod（plugin.json 已足够）
}
```

#### 3. PromptExecutor 集成剪贴板复制

修改 task 004 输出的 PromptExecutor.execute()，在成功路径末尾追加：

```swift
// 成功译文非空时复制到剪贴板
if !text.isEmpty {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

return PluginResult(
    stdout: "\(text)\n\n_(已复制到剪贴板)_",  // markdown 渲染为斜体提示
    ...
)
```

**注意**：这是对 task 004 PromptExecutor 的小幅修改（剪贴板 + 提示行）。本 task 应记录"修改了 004 的输出"为偏差说明。

#### 4. buddy launcher inspect 输出 mode

修改 BuddyCLI 的 inspect 命令（如已存在）：

```swift
case "inspect":
    let manifest = try loadManifest(name: pluginName)
    let json: [String: Any] = [
        "name": manifest.name,
        "version": manifest.version,
        "description": manifest.description,
        "keywords": manifest.keywords,
        "mode": modeString(manifest.modeConfig),  // NEW: "stdin" | "prompt"
        // ... mode-specific fields
    ]
    print(JSONSerialization ...)
```

`modeString(modeConfig)`：mode-aware helper 返回 "stdin" 或 "prompt"。

### 不变 contract

- HelloPlugin / builtin-hello 安装与运行行为完全不变
- buddy launcher list / add / remove 命令不变
- LauncherUI 渲染不变

## 实现要点

1. **plugin.json 中 systemPrompt 包含换行**：JSON 中 `\n` 编码，loaded 后是真实换行
2. **剪贴板提示行格式**：用 markdown 斜体 `_(已复制到剪贴板)_`，MarkdownRenderer 渲染为浅色斜体（不抢译文风头）
3. **chmod 跳过的红队测试**：单元测试模拟 prompt mode bundle，断言 `setAttributes` **未被调用**（防回归引入 mode 检查漏掉）
4. **inspect mode 字段**：JSON schema 加 mode key（前向兼容客户端解析）

## 输入

- task 002 输出的 PluginManifest schema
- task 004 输出的 PromptExecutor（需小幅修改加剪贴板）
- task 005 输出的 trust mode-aware（首装弹 alert）
- 现有 `Sources/.../Launcher/Plugin/PluginManager.swift`
- 现有 `Sources/.../Plugins/HelloPlugin/` 作为安装模板

## 输出

- 新 `Sources/ClaudeCodeBuddy/Plugins/TranslatePlugin/plugin.json`
- 修改 `Sources/.../Launcher/Plugin/PluginManager.swift` installBundledPlugins() mode-aware
- 修改 task 004 输出的 PromptExecutor.swift 加剪贴板复制
- 修改 BuddyCLI inspect 命令加 mode 字段
- 修改 `Package.swift` 把 TranslatePlugin 加入 BuddyCore resources（如需）
- 端到端红队验收测试
- handoff `006-builtin-translate.handoff.md` 含：
  - 安装流程图（builtin-translate 部署到 ~/.buddy/launcher-plugins/）
  - PromptExecutor 修改说明（剪贴板复制 + 提示行）
  - inspect JSON schema 变化说明

## 验收标准（红队测试候选）

### Tier 1 单元测试

1. **plugin.json 合法**：JSONDecoder 解析 plugin.json → PluginManifest 成功，modeConfig == .prompt
2. **systemPrompt 内容正确**：解析后 systemPrompt 含 "中英互译"、"自动检测"、"不要任何解释" 关键短语
3. **installBundledPlugins 不对 prompt 文件 chmod**：mock FileManager，断言 setAttributes 未被调用 for prompt mode
4. **installBundledPlugins 仍对 stdin 文件 chmod**：HelloPlugin 路径 chmod 0o755 行为不变
5. **剪贴板复制**：mock NSPasteboard，PromptExecutor 成功响应非空 → NSPasteboard.general.setString 被调用 with 译文
6. **剪贴板提示行**：PromptExecutor 返回的 stdout 末尾含 `_(已复制到剪贴板)_`
7. **inspect 输出 mode**：`buddy launcher inspect builtin-translate` JSON 含 `"mode": "prompt"` + `"systemPrompt"` 字段（截断或全文，brief 定）
8. **inspect stdin 不破坏**：`buddy launcher inspect builtin-hello` 仍含 cmd/args 字段

### Tier 1.5 真实场景（端到端）

9. **SC-1 中→英翻译**：
   - 启动 app（make run）
   - 按 ctrl+space 召唤 launcher
   - 输入 "你好" → 等待响应
   - 验证 launcher 显示英文译文（含 "hello" 或类似）+ 提示 "(已复制到剪贴板)"
   - 切到任意编辑器 Cmd+V → 内容为译文

10. **SC-2 英→中翻译**：
    - 输入 "hello world" → 显示 "你好世界" 或语义等价

11. **SC-3 混合符号**：
    - 输入 "Hello, world! 这是测试。" → 译文保留标点结构

12. **SC-4 stdin 并存**：
    - 输入 "hello demo" → router 选中 builtin-hello（stdin）→ 输出 "## Hello, hello demo!"
    - 紧接着输入 "翻译 hello" → router 选中 builtin-translate（prompt）→ 输出译文
    - 两次互不干扰

13. **SC-10 复制反馈**：目视 UI 显示 "(已复制到剪贴板)" 文案，渲染为浅色

## 已识别风险

- **首装 trust alert**（SC-8）：用户首次跑会弹 alert，UX 中断。在 README / 启动 onboarding 说明
- **空译文**：LLM 返回空 → 不复制剪贴板（避免清空用户原剪贴板内容），仅返回空 stdout
- **剪贴板隐私**：复制译文可能含敏感信息——这是用户主动翻译操作，符合直觉，无需额外提示
- **PromptExecutor 跨 task 修改**：本 task 修改了 004 输出的 PromptExecutor，handoff 必须明确说明此偏差

## 时间预估

2-3 小时（含端到端真实场景验证 + 多个集成点）

## QA scope（避免 SpriteKit 卡顿）

```bash
swift test --filter Plugin --filter Prompt --filter Translate --filter Manager
# 或反向：swift test --skip Snapshot --skip CatSprite
```

端到端 Tier 1.5 需 `make run` 启动 app 后手动召唤 launcher（按 ctrl+space）实测翻译。`buddy launcher inspect` 在终端跑。
