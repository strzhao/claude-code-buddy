---
id: "004-blob"
depends_on: ["002-types"]
---

# 004: Vercel Blob 存储 helpers

## 目标

创建 `src/lib/storage.ts`，封装 Vercel Blob 的上传和删除操作。

## 架构上下文

Blob 路径约定: `skins/{id}/{version}/skin.zip` 和 `skins/{id}/{version}/preview.png`。Blob URL 是公开的持久链接，直接作为 `download_url` 返回给桌面端。

## 需要创建的函数

```typescript
import { put, del, list } from "@vercel/blob";

export async function uploadSkinZip(
  id: string, version: string, buffer: Buffer
): Promise<string>; // 返回 blob URL

export async function uploadPreviewImage(
  id: string, version: string, buffer: Buffer
): Promise<string>; // 返回 blob URL

export async function deleteSkinBlobs(
  id: string, version: string
): Promise<void>; // 删除 zip + preview
```

## 关键约束

- 路径使用 `BLOB_BASE_PATH` 常量前缀
- `put()` 使用 `{ access: "public" }` 选项
- `deleteSkinBlobs` 先 list 再批量 del（preview 可能不存在）

## 验收标准

- [ ] 函数签名和类型正确
- [ ] `npm run build` 通过
