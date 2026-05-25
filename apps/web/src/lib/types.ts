// Mirrors Swift MenuBarConfig (SkinPackManifest.swift)
export interface MenuBarConfig {
  walk_prefix: string;
  walk_frame_count: number;
  run_prefix: string;
  run_frame_count: number;
  idle_frame: string;
  directory: string;
}

// Mirrors Swift SkinVariant (SkinPackManifest.swift) — optional color variant
export interface SkinVariant {
  id: string;
  name: string;
  sprite_prefix: string;
  preview_image?: string;
  bed_names?: string[];
}

// Mirrors Swift SkinPackManifest (SkinPackManifest.swift) — snake_case keys
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
  variants?: SkinVariant[];
}

// What the desktop app's SkinPackStore decodes (SkinPackStore.swift lines 5-18)
export interface RemoteSkinEntry {
  id: string;
  name: string;
  author: string;
  version: string;
  preview_url: string | null;
  download_url: string;
  size: number;
  variant_count: number;
}

export type SkinStatus = "pending" | "approved" | "rejected";

// Full record stored in Redis (Upstash)
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
