/**
 * extract-and-upload-preview.ts
 *
 * 从 Blob 存储中下载皮肤 zip，提取 preview 图片，上传到 Blob，更新 Redis。
 *
 * 运行方式：
 *   npx tsx --env-file=.env.local scripts/extract-and-upload-preview.ts
 *   npx tsx --env-file=.env.local scripts/extract-and-upload-preview.ts --execute
 */

import { Redis } from "@upstash/redis";
import { put } from "@vercel/blob";
import JSZip from "jszip";

function redis(): Redis {
  const url = process.env.UPSTASH_REDIS_REST_URL ?? process.env.KV_REST_API_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN ?? process.env.KV_REST_API_TOKEN;
  if (!url || !token) {
    throw new Error("Missing Redis env vars");
  }
  return new Redis({ url, token });
}

interface SkinRecord {
  id: string;
  name: string;
  version: string;
  preview_blob_url: string | null;
  blob_url: string;
  sprite_directory: string;
  preview_image?: string;
  [key: string]: unknown;
}

async function main() {
  const isDryRun = !process.argv.includes("--execute");
  console.log(`=== extract-and-upload-preview (${isDryRun ? "DRY-RUN" : "EXECUTE"}) ===\n`);

  const r = redis();
  const cks = await r.smembers("skin-ids");

  for (const ck of cks) {
    const rec = await r.get<SkinRecord>(`skin:${ck}`);
    if (!rec) continue;

    // Skip skins that already have a preview
    if (rec.preview_blob_url) {
      console.log(`[skip] ${ck}: already has preview → ${rec.preview_blob_url}`);
      continue;
    }

    console.log(`\n--- ${ck} ---`);
    console.log(`  name: ${rec.name}`);
    console.log(`  blob_url: ${rec.blob_url}`);

    // 1. Download the zip
    console.log(`  Downloading zip...`);
    const zipResp = await fetch(rec.blob_url);
    if (!zipResp.ok) {
      console.log(`  [!] Failed to download zip: ${zipResp.status}`);
      continue;
    }
    const zipBuffer = Buffer.from(await zipResp.arrayBuffer());

    // 2. Parse manifest to find preview_image path
    const zip = await JSZip.loadAsync(zipBuffer);
    const manifestFile = zip.file("manifest.json");
    if (!manifestFile) {
      console.log(`  [!] No manifest.json in zip`);
      continue;
    }
    const manifest = JSON.parse(await manifestFile.async("text"));
    console.log(`  sprite_directory: ${manifest.sprite_directory}`);
    console.log(`  preview_image: ${manifest.preview_image ?? "(not set)"}`);

    // 3. Find preview file in zip
    let previewPath: string | null = null;
    let previewData: Buffer | null = null;

    if (manifest.preview_image) {
      previewPath = `${manifest.sprite_directory}/${manifest.preview_image}`;
      const pf = zip.file(previewPath);
      if (pf) {
        previewData = Buffer.from(await pf.async("nodebuffer"));
      }
    }

    // Fallback: try common preview file names
    if (!previewData) {
      const candidates = [
        `${manifest.sprite_directory}/preview.png`,
        "preview.png",
        `${manifest.sprite_directory}/${manifest.sprite_prefix}-idle-a-1.png`,
      ];
      for (const candidate of candidates) {
        const pf = zip.file(candidate);
        if (pf) {
          previewPath = candidate;
          previewData = Buffer.from(await pf.async("nodebuffer"));
          break;
        }
      }
    }

    if (!previewData || !previewPath) {
      // List all files in zip for debugging
      console.log(`  [!] No preview found. Files in zip:`);
      zip.forEach((path) => console.log(`    ${path}`));
      continue;
    }

    console.log(`  Found preview: ${previewPath} (${previewData.length} bytes)`);

    if (isDryRun) {
      console.log(`  [DRY-RUN] Would upload preview and update Redis. Add --execute to proceed.`);
      continue;
    }

    // 4. Upload preview to Blob
    const blobPath = `skins/${rec.id}/${rec.version}/preview.png`;
    const blob = await put(blobPath, previewData, { access: "public" });
    console.log(`  Uploaded preview: ${blob.url}`);

    // 5. Update Redis
    const updated = { ...rec, preview_blob_url: blob.url, updated_at: new Date().toISOString() };
    await r.set(`skin:${ck}`, updated);
    console.log(`  [OK] Redis updated`);
  }

  console.log("\n=== Done ===");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
