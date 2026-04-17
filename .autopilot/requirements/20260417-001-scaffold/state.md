---
active: true
phase: "design"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/vectorized-juggling-dream/.autopilot/project/tasks/001-scaffold.md"
next_task: ""
auto_approve: true
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/vectorized-juggling-dream/.autopilot/requirements/20260417-001-scaffold"
session_id: 934e27df-0831-4911-bdcb-70dbcbfa3ecd
started_at: "2026-04-17T15:08:06Z"
---

## 目标
---
id: "001-scaffold"
depends_on: []
---

# 001: Next.js 项目脚手架

## 目标

在当前 worktree 根目录创建 `claude-code-buddy-web/` 子目录，初始化 Next.js 项目。

## 架构上下文

这是一个独立的 Next.js Web 应用，最终会发布为独立 GitHub 仓库 `stringzhao/claude-code-buddy-web`。当前先在 worktree 内开发，完成后再推到独立 repo。

## 执行步骤

1. `npx create-next-app@latest claude-code-buddy-web` —— App Router, TypeScript, Tailwind CSS, src/ 目录, 不用 `--turbopack`
2. 安装依赖: `npm install jszip @vercel/blob @vercel/kv`
3. 创建 `.env.example`:
   ```
   BLOB_READ_WRITE_TOKEN=
   KV_REST_API_URL=
   KV_REST_API_TOKEN=
   ```
4. 创建 `middleware.ts` (auth 占位):
   ```typescript
   import { NextResponse } from "next/server";
   import type { NextRequest } from "next/server";
   export function middleware(_request: NextRequest) {
     return NextResponse.next();
   }
   export const config = {
     matcher: ["/admin/:path*", "/api/admin/:path*"],
   };
   ```
5. 确认 `npm run dev` 正常启动
6. 确认 `npm run build` 无错误

## 输出契约

- `claude-code-buddy-web/` 目录存在，`npm run dev` 可启动
- package.json 包含 jszip、@vercel/blob、@vercel/kv 依赖
- middleware.ts 已创建

## 验收标准

- [ ] `npm run dev` 在 localhost:3000 正常响应
- [ ] `npm run build` 无 TypeScript 错误
- [ ] middleware.ts 存在且匹配 admin 路由


--- 架构设计摘要 ---
# Claude Code Buddy Web — 皮肤包商店架构设计

## 系统概览

```
社区用户 ──→ H5 上传页 ──→ POST /api/upload ──→ [校验] ──→ Blob + KV (pending)
                                                                    │
CLI 工具 ──→ 本地校验 ──→ POST /api/upload ──────────────────────────┘
                                                                    │
管理员 ────→ Admin 页面 ──→ Admin APIs ──→ KV 状态流转 (approve/reject)
                                                                    │
桌面 App ──→ GET /api/skins ──→ KV (approved only) ──→ RemoteSkinEntry[]
```

## Tech Stack

- Next.js (App Router) + TypeScript + Tailwind CSS
- Vercel Blob (zip + preview) + Vercel KV (metadata)
- JSZip (服务端 zip 解析)
- 新独立 GitHub 仓库: `stringzhao/claude-code-buddy-web`

## 关键技术决策

1. `GET /api/skins` 返回桌面端 `RemoteSkinEntry[]` 格式（snake_case JSON）
2. KV: `skin:{id}:{version}` 主键 + Redis SET 按状态索引
3. CLI 本地预校验 + 服务端完整校验双层保障
4. `middleware.ts` 匹配 admin 路由，当前 pass-through，后续接入认证
5. 同一 id 仅允许一个 approved 版本出现在公开列表

## 数据模型

### KV Key Schema

| Key | Value | 用途 |
|-----|-------|------|
| `skin:{id}:{version}` | SkinRecord JSON | 主记录 |
| `skin-ids` | Redis SET | 全量索引 |
| `skin-ids:approved` | Redis SET | 已批准索引 |
| `skin-ids:pending` | Redis SET | 待审核索引 |
| `skin-ids:rejected` | Redis SET | 已拒绝索引 |

### API 响应字段映射

| SkinRecord 字段 | API 响应字段 | 说明 |
|----------------|-------------|------|
| `blob_url` | `download_url` | 直接下载 URL |
| `preview_blob_url` | `preview_url` | 可为 null |
| id/name/author/version/size | 同名透传 | |
| status/manifest/etc. | 不输出 | 内部字段 |

## 跨任务设计约束

1. 所有 API 响应 snake_case（桌面端兼容关键）
2. 错误格式: `{ "error": "...", "details": "..." }`
3. KV pipeline 批量减少 RTT（非原子事务）
4. 上传上限 5MB；maxDuration: 60
5. reject 不删除 Blob；仅 delete API 同步删除
6. 并发写入用 KV SET NX 语义

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档
(待 design 阶段填充)

## 实现计划
(待 design 阶段填充)

## 红队验收测试
(待 implement 阶段填充)

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [2026-04-17T15:08:06Z] autopilot 初始化（brief 模式），任务: 001-scaffold.md
