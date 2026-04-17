---
id: "002-types"
depends_on: []
---

# 002: 共享类型、常量、错误处理

## 目标

创建 `src/lib/types.ts`、`src/lib/constants.ts`、`src/lib/errors.ts`，作为所有后续任务的公共契约。

## 架构上下文

所有类型必须与桌面端 Swift 代码 1:1 对应（snake_case JSON keys）。参考:
- `SkinPackManifest` → `Sources/ClaudeCodeBuddy/Skin/SkinPackManifest.swift`
- `RemoteSkinEntry` → `Sources/ClaudeCodeBuddy/Skin/SkinPackStore.swift`
- `MenuBarConfig` → `SkinPackManifest.swift` 中的嵌套结构

## 需要创建的文件

### src/lib/types.ts

```typescript
// MenuBarConfig — 镜像 Swift MenuBarConfig
export interface MenuBarConfig {
  walk_prefix: string;
  walk_frame_count: number;
  run_prefix: string;
  run_frame_count: number;
  idle_frame: string;
  directory: string;
}

// SkinPackManifest — 镜像 Swift SkinPackManifest（snake_case）
export interface SkinPackManifest {
  id: string;
  name: string;
  author: string;
  version: string;
  preview_image?: string;
  sprite_prefix: string;
  animation_names: string[];
  canvas_size: [number, number];
  bed_names: string[];
  boundary_sprite: string;
  food_names: string[];
  food_directory: string;
  sprite_directory: string;
  menu_bar: MenuBarConfig;
}

// RemoteSkinEntry — 桌面端 SkinPackStore 解码格式
export interface RemoteSkinEntry {
  id: string;
  name: string;
  author: string;
  version: string;
  preview_url: string | null;
  download_url: string;
  size: number;
}

export type SkinStatus = "pending" | "approved" | "rejected";

// 存储在 KV 中的完整记录
export interface SkinRecord {
  id: string;
  name: string;
  author: string;
  version: string;
  status: SkinStatus;
  manifest: SkinPackManifest;
  blob_url: string;
  preview_blob_url: string | null;
  size: number;
  rejection_reason?: string;
  created_at: string;
  updated_at: string;
}

export interface ApiError {
  error: string;
  details?: string;
}

export interface UploadResponse {
  success: true;
  skin: { id: string; name: string; status: SkinStatus };
}
```

### src/lib/constants.ts

```typescript
export const MAX_UPLOAD_SIZE = 5 * 1024 * 1024; // 5 MB
export const MAX_UNCOMPRESSED_SIZE = 50 * 1024 * 1024; // 50 MB
export const ZIP_BOMB_RATIO = 100;
export const KV_PREFIX = "skin";
export const KV_INDEX_ALL = "skin-ids";
export const KV_INDEX_APPROVED = "skin-ids:approved";
export const KV_INDEX_PENDING = "skin-ids:pending";
export const KV_INDEX_REJECTED = "skin-ids:rejected";
export const BLOB_BASE_PATH = "skins";
export const CACHE_MAX_AGE = 300; // 5 min edge cache
```

### src/lib/errors.ts

```typescript
import { NextResponse } from "next/server";
import type { ApiError } from "./types";

export function errorResponse(status: number, error: string, details?: string) {
  return NextResponse.json({ error, details } satisfies ApiError, { status });
}
```

## 验收标准

- [ ] `npm run build` 类型检查通过
- [ ] types.ts 中的 SkinPackManifest 字段与 Swift 版本 1:1 对应
