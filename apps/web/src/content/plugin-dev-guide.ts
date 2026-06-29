/**
 * Claude Code Buddy Launcher 插件开发指南（AI 可消费，自包含 markdown）。
 *
 * 「复制给 AI 使用」按钮会把本常量整体写入剪贴板。AI 拿到后即可照此开发插件。
 * 与 /plugin/docs 页面人类可读版同源（页面从本常量结构渲染），保证一致。
 *
 * 内容大纲（10 节）：
 *  1. 插件是什么
 *  2. plugin.json schema（含 summary）
 *  3. 三种 mode（stdin / command / prompt）
 *  4. 目录结构与 local-subdir
 *  5. 最小示例（hello 模板）
 *  6. 开发与调试（buddy launcher run / log / inspect）
 *  7. 安装使用（sideload + buddy launcher add）
 *  8. 合入社区（marketplace.json 注册 + PR）
 *  9. 安全模型（TOFU / requiredPath / 路径限制）
 * 10. summary / description 写作规范
 */

export const PLUGIN_DEV_GUIDE = `# Claude Code Buddy Launcher 插件开发指南

为 Claude Code Buddy 的 Launcher（Ctrl+Space 召唤的 AI 启动器）开发插件。
插件是「带 manifest 的可执行单元」，输入一段文字、产出一屏结果（文本 / 图片 / 候选列表）。

## 1. 插件是什么

Launcher 是一个浮窗输入框。用户输入文字后，按以下顺序处理：

1. 内置插件（计算器 / 剪贴板 / 应用启动 / 锁屏）即时给出候选；
2. 关键词命中外部插件（你写的这种）→ 直接执行；
3. 都没命中 → 走默认 AI 流（翻译 / 查词 / 问答）。

外部插件就是「关键词触发 → 跑一个子进程 → 把结果回显」。适合做：二维码生成、
服务状态查询、格式转换、查表、对接内部工具等确定性任务。

## 2. plugin.json schema

每个插件目录根放一个 \`plugin.json\`：

\`\`\`json
{
  "name": "my-plugin",
  "version": "0.1.0",
  "summary": "一句话说清这个插件干嘛（首屏展示）",
  "description": "详细说明：什么时候触发、产出什么、有哪些限制。",
  "keywords": ["my", "我的"],
  "mode": "stdin",
  "cmd": "./my-script.sh",
  "args": [],
  "env": null,
  "timeout": 10,
  "requiredPath": null
}
\`\`\`

字段说明：
- \`name\`：插件唯一 id，必须和目录名一致（或目录名后缀）。
- \`version\`：语义化版本。
- \`summary\`：一句话人话摘要，设置页和首屏展示。**写给人看，别写 stdin/stdout/协议这种黑话。**
- \`description\`：详细说明，设置页展开看。也写人话。
- \`keywords\`：触发词。用户输入命中任一关键词 → 执行本插件。
- \`mode\`：执行模式，见第 3 节。
- \`cmd\`：可执行文件相对路径（相对插件目录）。**禁绝对路径、禁 \`..\`**。
- \`args\`：命令行参数数组（可省略 = 空）。
- \`env\`：额外环境变量（可省略）。
- \`timeout\`：秒，超时杀进程（1-60，默认 10）。
- \`requiredPath\`：依赖的外部二进制名（如 \`["jq"]\`），缺则报错提示安装。
- \`parameters\`（可选）：JSON Schema，声明结构化参数契约。声明后，插件会作为 LLM tool 暴露给 AI 路由——用户输入自然语言（如「生成二维码 https://example.com」），LLM 选对插件并提取参数填入。**顶层 \`type\` 必须是 \`"object"\`**（框架会强制覆盖，防 API 400）。不声明则走固定 \`{query}\` 契约（用户原始查询作为单一字符串入参）。

\`\`\`json
{
  "name": "qr",
  "version": "0.3.0",
  "summary": "二维码生成器：输入文本或网址生成可扫码图片",
  "description": "把输入的文本或网址变成一张二维码图片。",
  "keywords": ["qr", "二维码"],
  "mode": "command",
  "cmd": "./qr-gen.sh",
  "parameters": {
    "type": "object",
    "properties": {
      "content": { "type": "string", "description": "要编码的文本或网址" }
    },
    "required": ["content"]
  }
}
\`\`\`

## 3. 三种 mode

### stdin mode（默认）
框架通过 stdin 传 JSON 给子进程：
\`\`\`json
{"query":"用户输入去掉触发词后的剩余","sessionId":"uuid","cwd":"当前目录"}
\`\`\`
子进程把 stdout 作为 markdown 文本回显。适合「LLM 调用工具」语义。
也可以写图片：设环境变量 \`BUDDY_OUTPUT_IMAGE\` 指向的 PNG 文件会被读取成图片卡片。

### command mode（零 LLM）
执行路径与 stdin 相同（复用 stdin 协议），但**绕过 AI agent loop**，
子进程直接产出。适合确定性任务（二维码、截图、状态查询）。
还支持候选通道：写 \`BUDDY_OUTPUT_CANDIDATES\` 指向的 JSON 文件，
格式 \`[{"id":"stop","title":"关闭","selection":"stop"}]\`，
用户点选后会以 \`selection\` 字段重入本插件执行选中动作。

### prompt mode（纯 LLM）
不跑子进程，直接把 system prompt 交给 LLM 单轮生成。
字段：\`systemPrompt\` / \`maxIterations\` / \`model\` / \`autoCopyToClipboard\`。
需要用户先配好 API provider。

## 4. 目录结构与 local-subdir

单插件目录：
\`\`\`
my-plugin/
├── plugin.json
├── my-script.sh      # cmd 指向的文件，必须 chmod +x
└──（其他资源、二进制）
\`\`\`

local-subdir（随 app 分发的官方插件）：
放在 app 仓库的 \`Marketplace/plugins/<name>/\` 下，\`plugin.json\` 的 \`source\` 字段
在 marketplace.json 里声明为字符串路径（如 \`"Marketplace/plugins/hello"\`），
首次启动 app 时自动 seed 到 \`~/.buddy/launcher-plugins/\`。

## 5. 最小示例（hello 模板）

\`\`\`bash
#!/usr/bin/env bash
# hello.sh — stdin mode 最小示例
set -euo pipefail
input="$(cat)"
query="$(printf '%s' "$input" | /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("query",""))
except Exception:
    print("")' 2>/dev/null || true)"
[ -z "$query" ] && query="朋友"
printf '👋 你好，**%s**！\\n\\n你输入的内容是：%s\\n' "$query" "$query"
\`\`\`

配套 plugin.json：
\`\`\`json
{
  "name": "hello",
  "version": "0.1.0",
  "summary": "问候示例：输入任意内容回显一句问候",
  "description": "入门示例插件，把输入原样回显成问候，演示插件的输入输出方式。",
  "keywords": ["hello", "问候", "示例"],
  "mode": "stdin",
  "cmd": "./hello.sh",
  "timeout": 5
}
\`\`\`

别忘了 \`chmod +x hello.sh\`。

## 6. 开发与调试

开发时不用每次召唤浮窗，直接用 CLI 驱动：

\`\`\`bash
# 直接执行具名插件（不经候选路由，即使输入不匹配关键词也会执行）
buddy launcher run hello --input "测试"

# 看完整结果 JSON
buddy launcher run hello --input "测试" --json

# 查看插件详情（含 summary / mode / trust 状态）
buddy launcher inspect hello

# 列出所有已装插件
buddy launcher list

# 看插件子系统日志（执行失败 / trust 拒绝都在这）
buddy log show --subsystem plugin

# 看最近的 error
buddy log show --level error
\`\`\`

\`buddy launcher run\` 是 dry-run：直接按插件名执行，不走候选匹配。
首次执行会弹 TOFU 信任框（见第 9 节），信任后不再重复弹。

## 7. 安装使用

### 本地侧载（sideload）
把插件目录放到 \`~/.buddy/launcher-plugins/<name>/\`，确保有 plugin.json 和可执行 cmd。
重启或 \`buddy launcher list\` 即可看到。

### 从 GitHub 安装
\`\`\`bash
buddy launcher add <user>/<repo>     # git clone --depth 1
buddy launcher list                  # 确认已装
buddy launcher inspect <name>        # 查看详情
buddy launcher remove <name>         # 卸载
\`\`\`

### 开关
\`\`\`bash
buddy launcher disable <name>        # 创建 .disabled 标记
buddy launcher enable <name>         # 移除标记
\`\`\`
或在 app 设置 → 插件页用开关（内置插件走独立开关，外部插件走 .disabled 文件）。

## 8. 合入社区

官方插件市场是仓库根的 \`marketplace/marketplace.json\`。把自己的插件加进去：

1. 插件源码放 \`Marketplace/plugins/<name>/\`（local-subdir）或独立 git 仓库（git-url）；
2. 在 \`marketplace.json\` 的 \`plugins\` 数组加一条：
   \`\`\`json
   {
     "name": "my-plugin",
     "version": "0.1.0",
     "description": "给市场清单看的简述（与 plugin.json.description 可不同）",
     "source": "Marketplace/plugins/my-plugin"
   }
   \`\`\`
   \`source\` 支持：字符串路径（local-subdir）、\`{type:"git-url", url, sha}\`、
   \`{type:"git-subdir", url, path, ref, sha}\`、\`{type:"file", path}\`；
3. 提 PR。合并后用户 \`buddy launcher install <name>\` 或 app 自动 sync 拉取。

## 9. 安全模型

### TOFU（Trust On First Use）
首次执行任何子进程插件会弹 NSAlert 确认。trust key = SHA256(cmd + args + sha256(可执行文件字节))。
任一改动（含二进制内容变化）→ 旧信任失效 → 重新弹框。trust 记录在 \`~/.buddy/launcher-trust.json\`。
mode 前缀隔离：stdin / command / prompt 的 trust key 互不相同，防止跨 mode 伪造。

### requiredPath
依赖外部二进制（如 jq / ffmpeg）时声明，缺失会提示安装而不是默默失败。

### 路径限制
\`cmd\` 禁绝对路径、禁 \`..\`（防路径穿越）。工作目录锁定在插件目录内。

## 10. summary / description 写作规范

\`summary\` 是用户第一眼看到的，写不好插件就没人用。

**好的 summary**（一句话，说清「输入什么 → 得到什么」）：
- ✅ \`二维码生成器：输入文本或网址生成可扫码图片\`
- ✅ \`计算器：输入算式即时算出结果，回车复制\`
- ✅ \`监控服务开关：一键查询并启停后台监控服务\`

**坏的 summary**（黑话 / 协议词 / 裸字段名）：
- ❌ \`演示 stdin/stdout markdown 协议\`（用户看不懂）
- ❌ \`QzhddrSrv 控制\`（内部代号）
- ❌ \`command mode 插件\`（实现细节）

**description** 是详情，可以详细些，但仍然写人话：
- 说清楚触发条件、产出形态（文字 / 图片 / 候选）、有没有副作用（写剪贴板 / 调系统命令）。
- 提到限制（需要 sudo、依赖某服务、可逆还是不可逆）。

**降级规则**：如果 plugin.json 没填 summary，展示层会取 description 的第一句（按 \`。\` / \`. \` / 换行切）作 summary；
都没有就用 name。所以**官方插件务必显式填 summary**，第三方插件缺失也不报错（向后兼容）。
`;
