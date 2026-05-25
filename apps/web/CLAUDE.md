@AGENTS.md

# Design System — Pixel Art × Sage Green

## Color Tokens

All UI must use semantic CSS custom property tokens via Tailwind utility classes. Never use raw Tailwind palette classes (e.g. `bg-gray-50`, `text-blue-600`).

### Core Tokens

| Utility class                 | Purpose                                       |
| ----------------------------- | --------------------------------------------- |
| `bg-canvas`                   | Page background                               |
| `bg-surface`                  | Cards, containers                             |
| `bg-surface-alt`              | Code blocks, alternate rows                   |
| `text-ink`                    | Primary body text                             |
| `text-secondary`              | Labels, metadata                              |
| `text-muted`                  | Descriptions, hints, placeholders             |
| `bg-primary` / `text-primary` | Brand Sage green — buttons, CTAs, active tabs |
| `bg-primary-hover`            | Hover state for brand elements                |
| `bg-primary-mist`             | Subtle brand background fill                  |
| `text-primary-text`           | Text on brand-colored backgrounds             |

### Semantic Status Tokens

| Prefix                                       | Purpose                  |
| -------------------------------------------- | ------------------------ |
| `success` / `success-light` / `success-text` | Approved, upload success |
| `warning` / `warning-light` / `warning-text` | Pending review           |
| `error` / `error-light` / `error-text`       | Rejected, errors, delete |
| `info` / `info-light` / `info-text`          | Links, informational     |

### Border & Focus

| Utility                       | Purpose                                         |
| ----------------------------- | ----------------------------------------------- |
| `border-border`               | Default subtle border                           |
| `border-border-strong`        | Input borders, emphasized                       |
| `border-border-pixel`         | Pixel-art hard border (used by `.pixel-border`) |
| `ring-focus` / `border-focus` | Focus rings and borders                         |

## Pixel Art Utility Classes

Defined in `globals.css`, compose with Tailwind utilities:

| Class                   | Effect                                          |
| ----------------------- | ----------------------------------------------- |
| `.pixel-shadow-sm`      | 2px hard-edge box shadow                        |
| `.pixel-shadow`         | 3px hard-edge box shadow                        |
| `.pixel-shadow-lg`      | 4px hard-edge box shadow                        |
| `.pixel-shadow-layered` | Double-step shadow                              |
| `.pixel-shadow-primary` | Brand-colored shadow                            |
| `.pixel-border`         | 2px solid pixel border                          |
| `.pixel-border-primary` | 2px brand-colored border                        |
| `.pixel-corners`        | CSS pseudo-element L-bracket corner decorations |
| `.pixel-render`         | `image-rendering: pixelated` for sprites        |
| `.pixel-heading`        | Geist Mono font, bold, tracked                  |
| `.pixel-btn-active`     | :active press translate + shadow removal        |
| `.pixel-divider`        | 2px dashed divider                              |

## Theme System

- Light/dark toggle via `.dark` class on `<html>`
- `ThemeProvider` (client component) manages state via React Context + localStorage
- Inline `<script>` in layout prevents flash of wrong theme (FOWT)
- All semantic tokens have both light and dark values in `globals.css`

## UI Patterns

- **Cards**: `rounded bg-surface pixel-border pixel-shadow-sm`
- **Primary buttons**: `rounded bg-primary text-primary-text pixel-shadow-sm pixel-btn-active hover:bg-primary-hover`
- **Secondary buttons**: `rounded border border-border-strong bg-surface text-secondary pixel-shadow-sm pixel-btn-active`
- **Status badges**: `border-2 font-mono text-[10px] uppercase tracking-wider` + status tokens
- **Sprite images**: Always add `pixel-render` class
- **Headings**: Use `pixel-heading` for page titles

# Claude Code Buddy — Skin Store

皮肤包商店 Web 应用，用于上传、审核、分发 Claude Code Buddy macOS 应用的精灵皮肤包。

## 技术栈

- **框架**: Next.js 16 (App Router) + React 19 + TypeScript
- **样式**: Tailwind CSS v4
- **存储**: Upstash Redis (KV) + Vercel Blob (文件)
- **部署**: Vercel
- **测试**: Vitest (单元/集成) + Playwright (E2E)
- **代码质量**: ESLint + Prettier + husky + lint-staged + commitlint

## 项目架构

```
src/
├── app/
│   ├── api/
│   │   ├── skins/route.ts          # GET /api/skins — 公共接口，返回已批准皮肤
│   │   ├── upload/route.ts         # POST /api/upload — 上传皮肤 zip
│   │   ├── auth/
│   │   │   ├── login/route.ts      # GET — 生成 CSRF state + 302 到账号中心
│   │   │   ├── callback/route.ts   # GET — JWT 验证 + 创建网关会话 cookie
│   │   │   └── logout/route.ts     # GET/POST — 清除会话 cookie + 302 到首页
│   │   └── admin/skins/            # 管理后台 API（需认证）
│   │       ├── route.ts            # GET — 按状态列出皮肤
│   │       └── [id]/
│   │           ├── route.ts        # DELETE — 删除皮肤
│   │           ├── approve/route.ts # POST — 批准皮肤
│   │           └── reject/route.ts  # POST — 拒绝皮肤
│   ├── upload/page.tsx             # 上传页面
│   ├── admin/page.tsx              # 管理后台页面
│   ├── error.tsx                   # 错误边界
│   ├── global-error.tsx            # 全局错误边界
│   ├── layout.tsx                  # 根布局
│   └── page.tsx                    # 首页
├── components/
│   ├── UploadForm.tsx              # 上传表单
│   ├── AdminDashboard.tsx          # 管理仪表板
│   ├── StatusBadge.tsx             # 状态标签
│   └── landing/
│       ├── CatSkinCard.tsx         # 首页硬编码默认猫咪皮肤卡片（hover 帧动画）
│       ├── SkinCard.tsx            # 皮肤卡片（已上架皮肤展示）
│       └── SkinsSection.tsx        # 首页皮肤商店区块
└── lib/
    ├── types.ts                    # 共享 TypeScript 类型
    ├── constants.ts                # 全局常量
    ├── errors.ts                   # 错误响应工具
    ├── auth.ts                     # 认证工具（HMAC 会话 cookie + admin 检查）
    ├── kv.ts                       # Upstash Redis 客户端封装
    ├── storage.ts                  # Vercel Blob 存储封装
    └── validation.ts               # ZIP 验证 + 预览图提取
```

## 开发命令

```bash
npm run dev          # 启动开发服务器 (localhost:3000)
npm run build        # 生产构建
npm run lint         # ESLint 检查
npm run lint:fix     # ESLint 自动修复
npm run format       # Prettier 格式化
npm test             # 运行单元/集成测试 (Vitest)
npm run test:watch   # 测试监听模式
npm run test:e2e     # 运行 E2E 测试 (Playwright)
npm run size         # 检查 bundle 大小
```

## 环境变量

参见 `.env.example`：

- `BLOB_READ_WRITE_TOKEN` — Vercel Blob 读写令牌
- `UPSTASH_REDIS_REST_URL` — Upstash Redis REST URL
- `UPSTASH_REDIS_REST_TOKEN` — Upstash Redis REST Token
- `APP_BASE_URL` — 应用基础 URL（生产: https://buddy.stringzhao.life）
- `AUTH_GATEWAY_SESSION_SECRET` — HMAC-SHA256 网关会话签名密钥
- `AUTH_ADMIN_EMAILS` — 管理员邮箱列表，逗号分隔（当前: zhaoguixiong@corp.netease.com）

## 开发约定

- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/)
- pre-commit hook 自动运行 lint-staged (ESLint + Prettier)
- API 路由统一使用 `errorResponse()` 返回错误
- 所有路由 handler 包裹 try/catch，catch 内返回 500
- Redis 键命名: `skin:{id}:{version}`，索引集: `skin-ids:*`
- Blob 路径: `skins/{id}/{version}/skin.zip`

## 认证系统

基于 [user.stringzhao.life](https://user.stringzhao.life) 统一账号体系（base-account）。

- **账号中心**: https://user.stringzhao.life
- **服务标识**: `svc-buddy` (origin: buddy.stringzhao.life)
- **SDK**: `@stringzhao/auth-sdk`（JWT 验证，基于 jose，Edge Runtime 兼容）
- **JWT 配置**: issuer=`https://user.stringzhao.life`, audience=`base-account-client`, JWKS=`/.well-known/jwks.json`

### 认证流程

1. 访问 `/admin` → middleware 检查 `buddy_gateway_session` cookie
2. 无有效会话 → 302 到 `/api/auth/login` → 302 到账号中心 `/authorize`
3. 登录后回调 `/api/auth/callback` → 验证 JWT → 检查 admin 邮箱 → 创建 HMAC 签名会话 cookie
4. 会话 cookie 格式: `base64url(JSON).base64url(HMAC-SHA256)`, TTL 12h, httpOnly/secure/sameSite:lax

### 权限模型

- 公共路由（/api/skins, /api/upload, /upload）: 无需登录
- Admin 路由（/admin/\*, /api/admin/\*）: 需要认证 + admin 邮箱匹配
- 无会话 → 页面 302 重定向 / API 401
- 有会话但非 admin → 403
- `AUTH_ADMIN_EMAILS` 环境变量控制管理员列表（逗号分隔，大小写不敏感）

### 关键文件

- `src/lib/auth.ts` — Web Crypto API 实现，Edge Runtime 兼容（不使用 Node.js crypto）
- `middleware.ts` — 会话验证 + admin 权限检查（Edge Runtime）
- `src/app/api/auth/` — login / callback / logout 三个路由

## Vercel 部署配置变更（迁移到 monorepo 后必做）

⚠️ **整合迁移到主仓库后，必须先完成以下 Vercel Dashboard 配置变更，才能触发下一次部署。否则会因仓库根没有 package.json 而失败。**

在 Vercel Dashboard → 项目 `claude-code-buddy-web` → Settings → General：

1. **Root Directory** 改为 `apps/web`，勾选 "Include source files outside of the Root Directory in the Build Step"
2. **Install Command** override 为：`cd ../.. && pnpm install --filter @stringzhao/web... --frozen-lockfile`
3. **Build Command** override 为：`pnpm --filter @stringzhao/web build`
4. **Output Directory** 保持 `.next`（相对 Root Directory）
