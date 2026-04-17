---
id: "008-api-admin"
depends_on: ["003-kv", "004-blob"]
---

# 008: Admin APIs

## 目标

创建管理员 API 端点: list、approve、reject、delete。

## 需要创建的路由文件

### GET /api/admin/skins — `src/app/api/admin/skins/route.ts`

- Query: `?status=pending|approved|rejected|all` (默认 pending)
- 调用 `listSkinsByStatus(status)`
- 返回 `SkinRecord[]`（完整记录，含 manifest）

### POST /api/admin/skins/[id]/approve — `src/app/api/admin/skins/[id]/approve/route.ts`

- `[id]` 是 URL-encoded composite key (`{skinId}:{version}`)
- 获取记录 → 404 if missing
- Guard: status === "pending" → 400 if not
- `moveSkinStatus(key, "pending", "approved", { updated_at: now })`
- 返回更新后的 SkinRecord

### POST /api/admin/skins/[id]/reject — `src/app/api/admin/skins/[id]/reject/route.ts`

- Body: `{ reason: string }`
- 同 approve 流程，但目标状态 "rejected"
- 更新 `rejection_reason` 和 `updated_at`
- reject 不删除 Blob 文件（保留审计）

### DELETE /api/admin/skins/[id] — `src/app/api/admin/skins/[id]/route.ts`

- 获取记录 → 404 if missing
- `deleteSkinBlobs(id, version)` 删除 Blob 文件
- `deleteSkinRecord(key)` 清理 KV
- 返回 204 No Content

## 依赖

- `src/lib/kv.ts` — 所有 CRUD 函数
- `src/lib/storage.ts` — `deleteSkinBlobs`
- `src/lib/errors.ts` — `errorResponse`

## 验收标准

- [ ] GET 按 status 过滤正确
- [ ] approve 将 pending → approved + 更新索引
- [ ] reject 保存 reason + 不删除 Blob
- [ ] delete 同步清理 KV + Blob
- [ ] `npm run build` 通过
