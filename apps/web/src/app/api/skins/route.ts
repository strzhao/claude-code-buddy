import { NextResponse } from "next/server";

import { CACHE_MAX_AGE, REDIS_READ_TIMEOUT_MS } from "@/lib/constants";
import { errorResponse } from "@/lib/errors";
import { listSkinsByStatus } from "@/lib/kv";
import { withTimeout } from "@/lib/timeout";
import type { RemoteSkinEntry, SkinRecord } from "@/lib/types";

function toRemoteSkinEntry(record: SkinRecord): RemoteSkinEntry {
  return {
    id: record.id,
    name: record.name,
    author: record.author,
    version: record.version,
    preview_url: record.preview_blob_url,
    download_url: record.blob_url,
    size: record.size,
    variant_count: record.manifest.variants?.length ?? 0,
  };
}

export async function GET() {
  try {
    // Fail fast on a Redis outage instead of hanging on the client's backoff
    // retries; the catch below turns this into a prompt 500.
    const approved = await withTimeout(
      listSkinsByStatus("approved"),
      REDIS_READ_TIMEOUT_MS,
      "redis read timed out",
    );

    // Deduplicate by id (keep latest version per id, comparing created_at)
    const latestById = new Map<string, SkinRecord>();
    for (const record of approved) {
      const existing = latestById.get(record.id);
      if (
        !existing ||
        new Date(record.created_at).getTime() > new Date(existing.created_at).getTime()
      ) {
        latestById.set(record.id, record);
      }
    }

    const entries: RemoteSkinEntry[] = Array.from(latestById.values()).map(toRemoteSkinEntry);

    return NextResponse.json(entries, {
      headers: {
        "Cache-Control": `public, s-maxage=${CACHE_MAX_AGE}, stale-while-revalidate=${CACHE_MAX_AGE * 2}`,
      },
    });
  } catch {
    return errorResponse(500, "Internal server error");
  }
}
