# Claude Code Buddy — Skin Store

皮肤包商店 Web 应用，为 [Claude Code Buddy](https://github.com/user/claude-code-buddy) macOS 桌面宠物提供精灵皮肤包的上传、审核和分发服务。

## 功能

- **上传皮肤包** — 支持 ZIP 格式上传，自动验证 manifest 和精灵文件完整性
- **管理后台** — 按状态筛选（待审核/已批准/已拒绝），支持批准、拒绝、删除操作
- **公共 API** — macOS 客户端通过 REST API 获取已批准的皮肤列表及下载链接
- **安全验证** — ZIP 炸弹检测、路径穿越防护、文件大小限制

## 技术栈

- [Next.js 16](https://nextjs.org/) (App Router)
- [React 19](https://react.dev/)
- [TypeScript](https://www.typescriptlang.org/) (strict mode)
- [Tailwind CSS v4](https://tailwindcss.com/)
- [Upstash Redis](https://upstash.com/) — 皮肤记录存储
- [Vercel Blob](https://vercel.com/docs/storage/vercel-blob) — ZIP 文件和预览图存储

## 本地开发

### 前置条件

- Node.js 20+
- npm

### 启动

```bash
# 1. 安装依赖
npm install

# 2. 配置环境变量
cp .env.example .env.local
# 填入 Upstash Redis 和 Vercel Blob 凭据

# 3. 启动开发服务器
npm run dev
```

访问 [http://localhost:3000](http://localhost:3000)

### 测试

```bash
npm test             # 单元/集成测试
npm run test:e2e     # E2E 测试 (需要 dev server)
npm run test:coverage # 带覆盖率的测试
```

## API 端点

| 方法   | 路径                           | 说明                                            |
| ------ | ------------------------------ | ----------------------------------------------- |
| GET    | `/api/skins`                   | 获取所有已批准皮肤（公共，5 分钟缓存）          |
| POST   | `/api/upload`                  | 上传皮肤包 ZIP（multipart/form-data）           |
| GET    | `/api/admin/skins?status=`     | 按状态列出皮肤（pending/approved/rejected/all） |
| POST   | `/api/admin/skins/:id/approve` | 批准皮肤                                        |
| POST   | `/api/admin/skins/:id/reject`  | 拒绝皮肤（可选 reason）                         |
| DELETE | `/api/admin/skins/:id`         | 删除皮肤及其 Blob 文件                          |

## 部署

项目部署在 Vercel 上。推送到 `main` 分支会自动触发部署。

## 许可证

MIT
