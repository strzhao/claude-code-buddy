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
