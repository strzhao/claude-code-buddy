---
id: "005-validation"
depends_on: ["002-types"]
---

# 005: Zip 校验逻辑

## 目标

创建 `src/lib/validation.ts`，实现皮肤包 zip 的完整服务端校验。

## 架构上下文

校验逻辑镜像桌面端 `SkinPackStore.downloadSkin()` 的验证步骤，并扩展了字段级检查和安全防护。使用 JSZip 内存解析，无需文件系统。

## 校验步骤（10 步）

1. 解析 zip（JSZip.loadAsync）
2. manifest.json 存在于 zip 根目录
3. manifest.json 是合法 JSON
4. 必填 string 字段: id, name, author, version, sprite_prefix, boundary_sprite, food_directory, sprite_directory
5. 必填 array 字段: animation_names, bed_names, food_names（非空数组）
6. canvas_size 是 `[正数, 正数]`（恰好 2 元素）
7. menu_bar 对象完整: walk_prefix, run_prefix, idle_frame, directory (string) + walk_frame_count, run_frame_count (正整数)
8. 关键精灵: `{sprite_directory}/{sprite_prefix}-idle-a-1.png` 存在于 zip
9. id 格式: `/^[a-z0-9][a-z0-9-]*[a-z0-9]$/i`，version 格式: `/^\d+\.\d+\.\d+$/`
10. zip bomb 防护: 检查各文件 compressed/uncompressed 比率 (>100x 拒绝)，总解压大小 <=50MB

## 需要导出的接口

```typescript
export interface ValidationResult {
  valid: boolean;
  manifest?: SkinPackManifest;
  errors: string[];
}

export async function validateSkinZip(buffer: ArrayBuffer): Promise<ValidationResult>;

export async function extractPreviewImage(
  buffer: ArrayBuffer, manifest: SkinPackManifest
): Promise<Buffer | null>;
// 从 zip 中提取 manifest.preview_image 指定的文件
```

## 验收标准

- [ ] 对合法 manifest 返回 `{ valid: true, manifest }`
- [ ] 对缺少 manifest.json 的 zip 返回 `{ valid: false, errors: ["manifest.json not found..."] }`
- [ ] 对缺少必填字段返回具体字段名错误
- [ ] `npm run build` 通过
