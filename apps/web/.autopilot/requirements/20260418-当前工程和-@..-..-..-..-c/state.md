---
active: true
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy-web/.claude/worktrees/account/.autopilot/requirements/20260418-当前工程和-@..-..-..-..-c"
session_id: b608a9c3-edd1-44d7-bbd6-05784709bd19
started_at: "2026-04-18T11:43:15Z"
---

## 目标

当前工程和 @../../../../claude-code-buddy 都接入 https://user.stringzhao.life/docs 账号体系 1. 默认不需要登录 2. 给 zhaoguixiong@corp.netease.com 设置管理员，用于皮肤包审核（皮肤包之前没有权限控制）

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### 目标

为 Web 项目 admin 路由接入 base-account 账号体系，实现基于邮箱的管理员权限控制。

### 技术方案

**认证流程（OAuth 风格）：**

1. 用户访问 `/admin` → middleware 检查 gateway session cookie
2. 无有效 session → 重定向到 `/api/auth/login` → 302 到 `https://user.stringzhao.life/authorize?return_to=<callback>&state=<random>`
3. 用户在账号中心登录 → 回调到 `/api/auth/callback?authorized=1&state=<state>`
4. Callback handler 读取共享 `access_token` cookie → 用 `@stringzhao/auth-sdk` 验证 JWT → 提取 email
5. 检查 email 是否在管理员列表 → 创建 HMAC-SHA256 签名的 gateway session cookie → 重定向到 `/admin`

**Gateway Session Cookie 设计：**

- Cookie 名: `buddy_gateway_session`
- 格式: `base64url(JSON payload) + "." + base64url(HMAC-SHA256 signature)`
- Payload: `{ email, issuedAt, expiresAt }`
- TTL: 12 小时
- Flags: httpOnly, secure (prod), sameSite: lax, path: /

**文件影响范围：**

| 文件                                 | 操作 | 说明                                 |
| ------------------------------------ | ---- | ------------------------------------ |
| `package.json`                       | 修改 | 添加 `@stringzhao/auth-sdk` 依赖     |
| `src/lib/auth.ts`                    | 新建 | Session cookie 创建/验证、admin 检查 |
| `middleware.ts`                      | 修改 | 添加 session 验证和 admin 权限检查   |
| `src/app/api/auth/login/route.ts`    | 新建 | 生成 state + redirect 到账号中心     |
| `src/app/api/auth/callback/route.ts` | 新建 | JWT 验证 + session 创建 + redirect   |
| `src/app/api/auth/logout/route.ts`   | 新建 | 清除 session cookie                  |
| `src/components/AdminDashboard.tsx`  | 修改 | 顶部添加用户信息和登出按钮           |
| `src/app/admin/page.tsx`             | 修改 | 读取 session 传递 user info          |
| `.env.example`                       | 修改 | 添加 auth 相关环境变量               |

## 实现计划

- [x] **T1: 安装依赖** — `npm install @stringzhao/auth-sdk`
- [x] **T2: 创建 auth 工具库** `src/lib/auth.ts`
- [x] **T3: 创建登录路由** `src/app/api/auth/login/route.ts`
- [x] **T4: 创建回调路由** `src/app/api/auth/callback/route.ts`
- [x] **T5: 创建登出路由** `src/app/api/auth/logout/route.ts`
- [x] **T6: 更新 middleware** `middleware.ts`
- [x] **T7: 更新 Admin 页面** `src/app/admin/page.tsx` + `AdminDashboard.tsx`
- [x] **T8: 更新环境变量** `.env.example`

## 红队验收测试

**测试文件：**

- `src/lib/__tests__/auth.acceptance.test.ts` — Session cookie 创建/验证、admin 邮箱检查、跨系统数据流（22 tests）
- `src/__tests__/middleware.acceptance.test.ts` — Middleware 鉴权逻辑（17 tests）
- `src/__tests__/auth-routes.acceptance.test.ts` — Auth 路由（login/callback/logout）（13 tests）

**验收标准：**

- 52 个测试全部通过
- 红队发现的 2 个 bug（TTL 单位、非管理员 403）已修复

## QA 报告

### Wave 1 — 命令执行

| Tier | 检查项              | 结果            | 证据                                                     |
| ---- | ------------------- | --------------- | -------------------------------------------------------- |
| 0    | 红队验收测试        | ✅ 52/52 passed | `vitest run` — 3 files, 52 tests, 0 failures             |
| 1    | TypeScript 类型检查 | ✅              | `tsc --noEmit` — 0 errors                                |
| 1    | Next.js 构建        | ✅              | `next build` — 成功，所有路由正确注册（含 /api/auth/\*） |

### Wave 1.5 — 真实场景验证

| 场景                     | 结果 | 说明                                                                                                                                                                        |
| ------------------------ | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 公共 API 无需认证        | ✅   | `GET /api/skins` 返回 500（Redis 未配置），非 302/401，middleware 未拦截                                                                                                    |
| Upload 页面无需认证      | ✅   | `GET /upload` 返回 200                                                                                                                                                      |
| Admin 页面未登录重定向   | ⚠️   | worktree 嵌套导致 turbopack 读取主仓库旧 middleware，dev server 无法验证。但 middleware 函数已通过 17 个直接调用测试（包括无 session → 302、无效 cookie → 302、过期 → 302） |
| Admin API 未登录返回 401 | ⚠️   | 同上。测试覆盖：无 session → 401 JSON、无效 cookie → 401、过期 → 401                                                                                                        |
| 非管理员返回 403         | ⚠️   | 同上。测试覆盖：非 admin 邮箱 → 页面 403、API 403                                                                                                                           |
| 登出清除 session         | ✅   | 通过 route handler 直接调用测试验证：302 + Set-Cookie Max-Age=0                                                                                                             |

**注**：⚠️ 表示无法通过 dev server HTTP 请求验证，但已通过单元/集成测试直接调用函数验证。根因是 git worktree 嵌套在主仓库下，turbopack 推断 workspace root 为主仓库，加载了主仓库的旧 middleware.ts。此问题仅影响 worktree 中的本地开发，不影响 Vercel 生产部署。

### Wave 2 — AI 审查

**Tier 2a: 设计符合性 — PASS**

- 9/9 设计要求全部验证通过
- 2 个 Minor 观察（middleware 403 无 body vs callback 403 有 HTML；空 email 防御逻辑）

**Tier 2b: 代码质量 — PASS**（修复后）

- 3 个 Important 安全问题已修复：
  - `return_to` 开放重定向 → 添加 `startsWith("/") && !startsWith("//")` 校验
  - `timingSafeCompare` 长度提前返回 → 改为常量时间 XOR 比较
  - callback 403 页面 email 未转义 → 添加 HTML 实体转义
- 4 个 Minor（可选改进，不阻塞）

### 结论

**全部 ✅**（含 ⚠️ 降级验证项）— 可进入审批。

## 变更日志

- [2026-04-18T14:13:26Z] 用户批准验收，进入合并阶段
- [2026-04-18T14:15:00Z] merge 阶段完成。commit 8148777。知识提取跳过（非公司项目）。phase: done。
- [2026-04-18T11:43:15Z] autopilot 初始化，目标: 当前工程和 @../../../../claude-code-buddy 都接入 https://user.stringzhao.life/docs 账号体系 1. 默认不需要登录 2. 给 zhaoguixiong@corp.netease.com 设置管理员，用于皮肤包审核（皮肤包之前没有权限控制）
- [2026-04-18T11:55:00Z] design 阶段完成，方案通过 Plan Reviewer 审查（PASS），用户批准。范围限定为 Web 项目，macOS 端不改动。进入 implement 阶段。
- [2026-04-18T12:10:00Z] implement 阶段完成。蓝队 8 个任务全部完成。红队生成 52 个验收测试，发现 2 个 bug（TTL 单位 + 非管理员 403），已修复。52/52 测试通过，tsc 通过。进入 qa 阶段。
- [2026-04-18T14:10:00Z] qa 阶段完成。Wave 1 全部 ✅（Tier 0/1），Wave 1.5 部分降级验证（worktree turbopack 限制），Wave 2 设计/代码审查 PASS。修复了 3 个 Important 安全问题（开放重定向、时序安全、XSS）。auth.ts 从 Node.js crypto 迁移到 Web Crypto API 以支持 Edge Runtime。gate: review-accept。
