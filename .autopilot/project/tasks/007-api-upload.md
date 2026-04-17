---
id: "007-api-upload"
depends_on: ["003-kv", "004-blob", "005-validation"]
---

# 007: POST /api/upload 上传端点

## 目标

创建 `src/app/api/upload/route.ts`，接收皮肤包 zip 上传，校验后存入 Blob + KV。

## 架构上下文

这是上传工作流的核心端点，同时被 H5 页面和 CLI 工具调用。校验在服务端完整执行，不依赖客户端预校验结果。

## 实现流程

1. 解析 multipart form data: `file` (Blob) + `author` (string, 可选覆盖)
2. 检查文件大小 <= MAX_UPLOAD_SIZE (5MB)，超过返回 413
3. 读取 zip 到 ArrayBuffer
4. 调用 `validateSkinZip(buffer)` —— 失败返回 400 + errors 数组
5. 提取 manifest
6. 重复检查: `skinExists(compositeKey(manifest.id, manifest.version))` —— 存在返回 409
7. 上传 zip 到 Blob: `uploadSkinZip(id, version, buffer)` → blob_url
8. 如果 manifest.preview_image 存在: `extractPreviewImage()` → `uploadPreviewImage()` → preview_blob_url
9. 创建 SkinRecord (status: "pending")
10. `setSkinRecordNX(record)` —— SET NX 防并发，失败返回 409
11. 返回 201 + UploadResponse

## 关键配置

```typescript
export const maxDuration = 60; // Vercel serverless 超时
export const dynamic = "force-dynamic";
```

## 依赖

- `src/lib/validation.ts` — `validateSkinZip`, `extractPreviewImage`
- `src/lib/kv.ts` — `skinExists`, `setSkinRecordNX`, `compositeKey`
- `src/lib/storage.ts` — `uploadSkinZip`, `uploadPreviewImage`
- `src/lib/errors.ts` — `errorResponse`
- `src/lib/constants.ts` — `MAX_UPLOAD_SIZE`

## 验收标准

- [ ] 合法 zip 上传返回 201
- [ ] 无 manifest.json 的 zip 返回 400 + 错误
- [ ] 超大文件返回 413
- [ ] 重复 id+version 返回 409
- [ ] `npm run build` 通过
