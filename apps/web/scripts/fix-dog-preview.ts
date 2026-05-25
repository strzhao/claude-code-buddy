/**
 * fix-dog-preview.ts
 *
 * 调查并修复 dog 皮肤封面（preview_blob_url）。
 *
 * 默认模式（dry-run）：打印 dog skin record + Blob 文件列表，不写入。
 * 执行模式：加 --execute 参数，将 preview_blob_url 更新到正确值。
 *
 * 运行方式（从项目根目录）：
 *   npx tsx --env-file=.env.local scripts/fix-dog-preview.ts
 *   npx tsx --env-file=.env.local scripts/fix-dog-preview.ts --execute
 */

import { Redis } from "@upstash/redis";
import { list } from "@vercel/blob";

// ---- Redis helpers ----

function redis(): Redis {
  const url = process.env.UPSTASH_REDIS_REST_URL ?? process.env.KV_REST_API_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN ?? process.env.KV_REST_API_TOKEN;
  if (!url || !token) {
    throw new Error("Missing UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN env vars");
  }
  return new Redis({ url, token });
}

interface SkinRecord {
  id: string;
  name: string;
  author: string;
  version: string;
  status: string;
  blob_url: string;
  preview_blob_url: string | null;
  created_at: string;
  updated_at: string;
  [key: string]: unknown;
}

async function listAllCks(): Promise<string[]> {
  const r = redis();
  return r.smembers("skin-ids");
}

async function getRecord(ck: string): Promise<SkinRecord | null> {
  const r = redis();
  return r.get<SkinRecord>(`skin:${ck}`);
}

async function setRecord(ck: string, record: SkinRecord): Promise<void> {
  const r = redis();
  await r.set(`skin:${ck}`, record);
}

// ---- Blob helpers ----

async function listBlobsForSkin(id: string): Promise<string[]> {
  const result = await list({ prefix: `skins/${id}/`, token: process.env.BLOB_READ_WRITE_TOKEN });
  return result.blobs.map((b) => b.url);
}

// ---- Main ----

async function main() {
  const isDryRun = !process.argv.includes("--execute");

  console.log(`=== fix-dog-preview.ts (${isDryRun ? "DRY-RUN" : "EXECUTE"}) ===\n`);

  // 1. Find dog skin records
  const cks = await listAllCks();
  console.log(`Redis 中共有 ${cks.length} 条 skin 记录\n`);

  const dogCks: string[] = [];
  for (const ck of cks) {
    if (ck.toLowerCase().includes("dog")) {
      dogCks.push(ck);
    }
  }

  if (dogCks.length === 0) {
    console.log("未找到包含 'dog' 的 skin 记录，尝试打印所有记录名称：");
    for (const ck of cks) {
      const rec = await getRecord(ck);
      if (rec) {
        console.log(`  ${ck} — name: ${rec.name}, preview: ${rec.preview_blob_url ?? "(null)"}`);
      }
    }
    return;
  }

  for (const ck of dogCks) {
    const rec = await getRecord(ck);
    if (!rec) {
      console.log(`[!] ${ck}: 记录不存在`);
      continue;
    }

    console.log(`--- Dog skin: ${ck} ---`);
    console.log(`  name:            ${rec.name}`);
    console.log(`  author:          ${rec.author}`);
    console.log(`  version:         ${rec.version}`);
    console.log(`  status:          ${rec.status}`);
    console.log(`  blob_url:        ${rec.blob_url}`);
    console.log(`  preview_blob_url: ${rec.preview_blob_url ?? "(null)"}`);
    console.log(`  created_at:      ${rec.created_at}`);

    // 2. List blobs for this skin
    const blobs = await listBlobsForSkin(rec.id);
    console.log(`\n  Blob 文件列表 (prefix=skins/${rec.id}/):`);
    if (blobs.length === 0) {
      console.log("    (无文件)");
    } else {
      for (const url of blobs) {
        console.log(`    ${url}`);
      }
    }

    // 3. Find best preview URL among blobs
    const previewBlob = blobs.find(
      (url) =>
        url.includes("preview") ||
        url.endsWith(".png") ||
        url.endsWith(".jpg") ||
        url.endsWith(".webp"),
    );

    if (!previewBlob) {
      console.log("\n  [!] 未能从 Blob 中找到合适的封面图，跳过");
      continue;
    }

    console.log(`\n  建议的 preview_blob_url: ${previewBlob}`);

    if (rec.preview_blob_url === previewBlob) {
      console.log("  preview_blob_url 已正确，无需修复");
      continue;
    }

    if (isDryRun) {
      console.log("  [DRY-RUN] 不执行写入。加 --execute 参数来应用修复。");
    } else {
      const updated: SkinRecord = {
        ...rec,
        preview_blob_url: previewBlob,
        updated_at: new Date().toISOString(),
      };
      await setRecord(ck, updated);
      console.log("  [OK] 已更新 preview_blob_url");
    }
  }

  console.log("\n=== 完成 ===");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
