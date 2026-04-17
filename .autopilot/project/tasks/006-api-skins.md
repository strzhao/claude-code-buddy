---
id: "006-api-skins"
depends_on: ["002-types", "003-kv"]
---

# 006: GET /api/skins 公开目录端点

## 目标

创建 `src/app/api/skins/route.ts`，提供桌面端可直接消费的皮肤包目录 API。

## 架构上下文

此端点替代桌面端当前使用的 `https://raw.githubusercontent.com/stringzhao/claude-code-buddy-skins/main/catalog.json`。响应格式必须与 Swift `RemoteSkinEntry` 1:1 对应。

## 实现要点

1. 从 KV 获取 `skin-ids:approved` SET 的所有成员
2. 批量获取 SkinRecord
3. 按 id 去重（同一 id 多版本只取最新 approved）
4. 映射为 RemoteSkinEntry:
   ```typescript
   {
     id: record.id,
     name: record.name,
     author: record.author,
     version: record.version,
     preview_url: record.preview_blob_url,
     download_url: record.blob_url,
     size: record.size,
   }
   ```
5. 设置 `Cache-Control: public, s-maxage=300, stale-while-revalidate=600`
6. 无 approved 皮肤时返回空数组 `[]`（不是错误）

## 依赖

- `src/lib/kv.ts` — `listSkinsByStatus("approved")`
- `src/lib/types.ts` — `RemoteSkinEntry`, `SkinRecord`

## 验收标准

- [ ] 响应 JSON 为 snake_case（download_url, preview_url）
- [ ] 仅返回 approved 皮肤，不暴露 status 等内部字段
- [ ] 有 Cache-Control header
- [ ] `npm run build` 通过
