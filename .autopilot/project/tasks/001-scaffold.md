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
