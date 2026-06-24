"use client";

import { useState } from "react";
import CodeBlock from "@/components/landing/CodeBlock";
import { PLUGIN_DEV_GUIDE } from "@/content/plugin-dev-guide";

// MARK: - 文档页（/plugin/docs）
//
// C7 契约：纯 JSX（无 MDX），复用 CodeBlock + 设计 token。
// 「复制给 AI 使用」按钮 navigator.clipboard.writeText(PLUGIN_DEV_GUIDE) + toast。
// 指南文本同时导出到 DOM（隐藏 textarea + data-copy-ai）供 curl 断言（场景 8）。
export default function PluginDocsPage() {
  const [copied, setCopied] = useState(false);

  const handleCopyForAI = async () => {
    try {
      await navigator.clipboard.writeText(PLUGIN_DEV_GUIDE);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard API 不可用（非 HTTPS）—— 降级：选中文本提示手动复制
      setCopied(false);
    }
  };

  return (
    <main className="min-h-full bg-canvas text-ink">
      <div className="mx-auto max-w-3xl px-4 py-12">
        {/* 标题区 */}
        <header className="mb-10">
          <h1 className="pixel-heading text-3xl mb-3">Launcher 插件开发文档</h1>
          <p className="text-secondary text-sm leading-relaxed">
            为 Claude Code Buddy 的 Launcher（Ctrl+Space 召唤的 AI 启动器）开发插件。 插件是带
            manifest 的可执行单元，输入文字、产出结果（文本 / 图片 / 候选）。
          </p>

          {/* 复制给 AI 按钮 */}
          <div className="mt-6 flex items-center gap-3">
            <button
              onClick={handleCopyForAI}
              data-copy-ai="true"
              className="rounded bg-primary text-primary-text pixel-shadow-sm pixel-btn-active px-4 py-2 text-sm font-medium hover:bg-primary-hover transition-colors"
              aria-label="复制给 AI 使用"
            >
              {copied ? "✓ 已复制到剪贴板" : "复制给 AI 使用"}
            </button>
            <span className="text-muted text-xs">
              一键复制完整自包含开发指南，粘贴给 AI 即可照此开发插件
            </span>
          </div>
        </header>

        {/* 章节渲染（10 节） */}
        <div className="space-y-12">
          <Section1 />
          <Section2 />
          <Section3 />
          <Section4 />
          <Section5 />
          <Section6 />
          <Section7 />
          <Section8 />
          <Section9 />
          <Section10 />
        </div>

        {/* 隐藏 textarea：指南完整文本导出到 DOM，供 curl 断言（场景 8） */}
        <textarea
          aria-hidden="true"
          data-plugin-guide="true"
          readOnly
          value={PLUGIN_DEV_GUIDE}
          className="sr-only"
          style={{ position: "absolute", left: "-9999px", width: "1px", height: "1px", opacity: 0 }}
        />
      </div>
    </main>
  );
}

// MARK: - 章节标题组件

function SectionTitle({ num, children }: { num: number; children: React.ReactNode }) {
  return (
    <h2 className="pixel-heading text-xl mb-4 flex items-baseline gap-2">
      <span className="text-primary">{num}.</span>
      <span>{children}</span>
    </h2>
  );
}

function Prose({ children }: { children: React.ReactNode }) {
  return <div className="text-secondary text-sm leading-relaxed space-y-3">{children}</div>;
}

// MARK: - 第 1 节：插件是什么

function Section1() {
  return (
    <section>
      <SectionTitle num={1}>插件是什么</SectionTitle>
      <Prose>
        <p>Launcher 是一个浮窗输入框。用户输入文字后，按以下顺序处理：</p>
        <ol className="list-decimal list-inside space-y-1 pl-2">
          <li>内置插件（计算器 / 剪贴板 / 应用启动 / 锁屏）即时给出候选；</li>
          <li>关键词命中外部插件（你写的这种）→ 直接执行；</li>
          <li>都没命中 → 走默认 AI 流（翻译 / 查词 / 问答）。</li>
        </ol>
        <p>
          外部插件就是「关键词触发 → 跑一个子进程 → 把结果回显」。适合做：
          二维码生成、服务状态查询、格式转换、查表、对接内部工具等确定性任务。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 2 节：plugin.json schema

function Section2() {
  return (
    <section>
      <SectionTitle num={2}>plugin.json schema</SectionTitle>
      <Prose>
        <p>
          每个插件目录根放一个 <code className="font-mono text-primary">plugin.json</code>：
        </p>
      </Prose>
      <div className="mt-3">
        <CodeBlock
          label="plugin.json"
          command={`{
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
}`}
        />
      </div>
      <Prose>
        <ul className="list-disc list-inside space-y-1 pl-2 mt-3">
          <li>
            <code className="font-mono">name</code>：插件唯一 id，必须和目录名一致（或目录名后缀）。
          </li>
          <li>
            <code className="font-mono">summary</code>：一句话人话摘要，设置页和首屏展示。
            <strong>写给人看，别写 stdin/stdout 这种黑话。</strong>
          </li>
          <li>
            <code className="font-mono">description</code>：详细说明，设置页展开看。也写人话。
          </li>
          <li>
            <code className="font-mono">keywords</code>：触发词。用户输入命中任一关键词 →
            执行本插件。
          </li>
          <li>
            <code className="font-mono">mode</code>：执行模式，见第 3 节。
          </li>
          <li>
            <code className="font-mono">cmd</code>：可执行文件相对路径。
            <strong>禁绝对路径、禁 ..</strong>。
          </li>
          <li>
            <code className="font-mono">requiredPath</code>：依赖的外部二进制名（如{" "}
            <code className="font-mono">[&quot;jq&quot;]</code>），缺则报错提示安装。
          </li>
        </ul>
      </Prose>
    </section>
  );
}

// MARK: - 第 3 节：三种 mode

function Section3() {
  return (
    <section>
      <SectionTitle num={3}>三种 mode（stdin / command / prompt）</SectionTitle>
      <Prose>
        <p>
          <strong className="text-ink">stdin mode</strong>（默认）：框架通过 stdin 传 JSON
          给子进程，子进程 stdout 作为 markdown 回显。适合「LLM 调用工具」语义。也支持图片通道{" "}
          <code className="font-mono">BUDDY_OUTPUT_IMAGE</code>。
        </p>
        <p>
          <strong className="text-ink">command mode</strong>（零 LLM）：执行路径与 stdin
          相同，但绕过 AI agent
          loop，子进程直接产出。适合确定性任务（二维码、状态查询）。还支持候选通道{" "}
          <code className="font-mono">BUDDY_OUTPUT_CANDIDATES</code>。
        </p>
        <p>
          <strong className="text-ink">prompt mode</strong>（纯 LLM）：不跑子进程，直接把 system
          prompt 交给 LLM 单轮生成。需要用户先配好 API provider。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 4 节：目录结构与 local-subdir

function Section4() {
  return (
    <section>
      <SectionTitle num={4}>目录结构与 local-subdir</SectionTitle>
      <Prose>
        <p>单插件目录：</p>
      </Prose>
      <div className="mt-3">
        <CodeBlock
          label="目录结构"
          command={`my-plugin/
├── plugin.json
├── my-script.sh      # cmd 指向的文件，必须 chmod +x
└──（其他资源、二进制）`}
        />
      </div>
      <Prose>
        <p className="mt-3">
          <strong className="text-ink">local-subdir</strong>（随 app 分发的官方插件）： 放在 app
          仓库的 <code className="font-mono">Marketplace/plugins/&lt;name&gt;/</code> 下，
          marketplace.json 里 <code className="font-mono">source</code> 声明为路径， 首启自动 seed
          到 <code className="font-mono">~/.buddy/launcher-plugins/</code>。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 5 节：最小示例

function Section5() {
  return (
    <section>
      <SectionTitle num={5}>最小示例（hello 模板）</SectionTitle>
      <div className="space-y-4">
        <CodeBlock
          label="hello.sh"
          command={`#!/usr/bin/env bash
# hello.sh — stdin mode 最小示例
set -euo pipefail
input="$(cat)"
query="$(printf '%s' "$input" | /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("query",""))
except Exception:
    print("")' 2>/dev/null || true)"
[ -z "$query" ] && query="朋友"
printf '👋 你好，**%s**！\\n\\n你输入的内容是：%s\\n' "$query" "$query"`}
        />
        <CodeBlock
          label="plugin.json"
          command={`{
  "name": "hello",
  "version": "0.1.0",
  "summary": "问候示例：输入任意内容回显一句问候",
  "description": "入门示例插件，把输入原样回显成问候，演示插件的输入输出方式。",
  "keywords": ["hello", "问候", "示例"],
  "mode": "stdin",
  "cmd": "./hello.sh",
  "timeout": 5
}`}
        />
      </div>
      <Prose>
        <p className="mt-3">
          别忘了 <code className="font-mono">chmod +x hello.sh</code>。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 6 节：开发与调试

function Section6() {
  return (
    <section>
      <SectionTitle num={6}>开发与调试</SectionTitle>
      <Prose>
        <p>开发时不用每次召唤浮窗，直接用 CLI 驱动：</p>
      </Prose>
      <div className="mt-3 space-y-2">
        <CodeBlock
          label="dry-run 直接执行具名插件"
          command={`buddy launcher run hello --input "测试"`}
        />
        <CodeBlock
          label="看完整结果 JSON"
          command={`buddy launcher run hello --input "测试" --json`}
        />
        <CodeBlock
          label="查看插件详情（含 summary / trust 状态）"
          command={`buddy launcher inspect hello`}
        />
        <CodeBlock label="列出所有已装插件" command={`buddy launcher list`} />
        <CodeBlock label="看插件子系统日志" command={`buddy log show --subsystem plugin`} />
      </div>
      <Prose>
        <p className="mt-3">
          <code className="font-mono">buddy launcher run</code> 是 dry-run：直接按插件名执行，
          不走候选匹配。首次执行会弹 TOFU 信任框（见第 9 节），信任后不再重复弹。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 7 节：安装使用

function Section7() {
  return (
    <section>
      <SectionTitle num={7}>安装使用（sideload + add）</SectionTitle>
      <Prose>
        <p>
          <strong className="text-ink">本地侧载（sideload）</strong>：把插件目录放到{" "}
          <code className="font-mono">~/.buddy/launcher-plugins/&lt;name&gt;/</code>，重启或{" "}
          <code className="font-mono">buddy launcher list</code> 即可看到。
        </p>
        <p>
          <strong className="text-ink">从 GitHub 安装</strong>：
        </p>
      </Prose>
      <div className="mt-3 space-y-2">
        <CodeBlock label="从 GitHub 装" command={`buddy launcher add <user>/<repo>`} />
        <CodeBlock
          label="开关"
          command={`buddy launcher disable <name>
buddy launcher enable <name>`}
        />
      </div>
    </section>
  );
}

// MARK: - 第 8 节：合入社区

function Section8() {
  return (
    <section>
      <SectionTitle num={8}>合入社区（marketplace.json + PR）</SectionTitle>
      <Prose>
        <p>
          官方插件市场是仓库根的 <code className="font-mono">marketplace/marketplace.json</code>
          。把自己的插件加进去：
        </p>
        <ol className="list-decimal list-inside space-y-1 pl-2">
          <li>
            插件源码放 <code className="font-mono">Marketplace/plugins/&lt;name&gt;/</code>
            （local-subdir）或独立 git 仓库（git-url）；
          </li>
          <li>
            在 <code className="font-mono">marketplace.json</code> 的{" "}
            <code className="font-mono">plugins</code> 数组加一条；
          </li>
          <li>
            提 PR。合并后用户 <code className="font-mono">buddy launcher install &lt;name&gt;</code>{" "}
            或 app 自动 sync 拉取。
          </li>
        </ol>
      </Prose>
      <div className="mt-3">
        <CodeBlock
          label="marketplace.json 注册"
          command={`{
  "name": "my-plugin",
  "version": "0.1.0",
  "description": "给市场清单看的简述",
  "source": "Marketplace/plugins/my-plugin"
}`}
        />
      </div>
    </section>
  );
}

// MARK: - 第 9 节：安全模型

function Section9() {
  return (
    <section>
      <SectionTitle num={9}>安全模型（TOFU / requiredPath / 路径限制）</SectionTitle>
      <Prose>
        <p>
          <strong className="text-ink">TOFU（Trust On First Use）</strong>
          ：首次执行任何子进程插件会弹 NSAlert 确认。trust key = SHA256(cmd + args +
          sha256(可执行文件字节))。任一改动 → 旧信任失效 → 重新弹框。trust 记录在{" "}
          <code className="font-mono">~/.buddy/launcher-trust.json</code>。mode 前缀隔离防跨 mode
          伪造。
        </p>
        <p>
          <strong className="text-ink">requiredPath</strong>：依赖外部二进制（如 jq /
          ffmpeg）时声明，缺失会提示安装而不是默默失败。
        </p>
        <p>
          <strong className="text-ink">路径限制</strong>：<code className="font-mono">cmd</code>{" "}
          禁绝对路径、禁 <code className="font-mono">..</code>
          （防路径穿越）。工作目录锁定在插件目录内。
        </p>
      </Prose>
    </section>
  );
}

// MARK: - 第 10 节：summary / description 写作规范

function Section10() {
  return (
    <section>
      <SectionTitle num={10}>summary / description 写作规范</SectionTitle>
      <Prose>
        <p>
          <code className="font-mono">summary</code> 是用户第一眼看到的，写不好插件就没人用。
        </p>
        <p>
          <strong className="text-ink">好的 summary</strong>（一句话，说清「输入什么 →
          得到什么」）：
        </p>
        <ul className="list-disc list-inside space-y-1 pl-2 text-success-text">
          <li>二维码生成器：输入文本或网址生成可扫码图片</li>
          <li>计算器：输入算式即时算出结果，回车复制</li>
        </ul>
        <p>
          <strong className="text-ink">坏的 summary</strong>（黑话 / 协议词 / 裸字段名）：
        </p>
        <ul className="list-disc list-inside space-y-1 pl-2 text-error-text">
          <li>演示 stdin/stdout markdown 协议</li>
          <li>command mode 插件</li>
        </ul>
        <p>
          <strong className="text-ink">降级规则</strong>：如果 plugin.json 没填 summary， 展示层会取
          description 的第一句作 summary；都没有就用 name。 所以
          <strong>官方插件务必显式填 summary</strong>，第三方插件缺失也不报错（向后兼容）。
        </p>
      </Prose>
    </section>
  );
}
