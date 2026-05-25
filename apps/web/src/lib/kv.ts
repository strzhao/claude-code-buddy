import { Redis } from "@upstash/redis";

import {
  REDIS_INDEX_ALL,
  REDIS_INDEX_APPROVED,
  REDIS_INDEX_PENDING,
  REDIS_INDEX_REJECTED,
  REDIS_PREFIX,
} from "./constants";
import type { SkinRecord, SkinStatus } from "./types";

let _redis: Redis | null = null;

function redis(): Redis {
  if (!_redis) {
    // Vercel Upstash integration injects KV_REST_API_URL / KV_REST_API_TOKEN
    // @upstash/redis fromEnv() expects UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN
    const url = process.env.UPSTASH_REDIS_REST_URL ?? process.env.KV_REST_API_URL;
    const token = process.env.UPSTASH_REDIS_REST_TOKEN ?? process.env.KV_REST_API_TOKEN;
    if (url && token) {
      _redis = new Redis({ url, token });
    } else {
      _redis = Redis.fromEnv();
    }
  }
  return _redis;
}

export function compositeKey(id: string, version: string): string {
  return `${id}:${version}`;
}

function kvKey(ck: string): string {
  return `${REDIS_PREFIX}:${ck}`;
}

function statusIndex(status: SkinStatus | "all"): string {
  switch (status) {
    case "pending":
      return REDIS_INDEX_PENDING;
    case "approved":
      return REDIS_INDEX_APPROVED;
    case "rejected":
      return REDIS_INDEX_REJECTED;
    case "all":
      return REDIS_INDEX_ALL;
  }
}

// Get a single skin record by composite key
export async function getSkinRecord(ck: string): Promise<SkinRecord | null> {
  return redis().get<SkinRecord>(kvKey(ck));
}

// Create a skin record ONLY if it doesn't exist (NX).
// Returns true if created, false if already exists.
export async function setSkinRecordNX(record: SkinRecord): Promise<boolean> {
  const ck = compositeKey(record.id, record.version);
  const key = kvKey(ck);

  const result = await redis().set(key, record, { nx: true });
  // @upstash/redis returns "OK" on success, null when NX condition not met
  if (result === null) {
    return false;
  }

  const pipe = redis().pipeline();
  pipe.sadd(REDIS_INDEX_ALL, ck);
  pipe.sadd(statusIndex(record.status), ck);
  await pipe.exec();

  return true;
}

// Delete a skin record + remove from all index sets
export async function deleteSkinRecord(ck: string): Promise<void> {
  const pipe = redis().pipeline();
  pipe.del(kvKey(ck));
  pipe.srem(REDIS_INDEX_ALL, ck);
  pipe.srem(REDIS_INDEX_PENDING, ck);
  pipe.srem(REDIS_INDEX_APPROVED, ck);
  pipe.srem(REDIS_INDEX_REJECTED, ck);
  await pipe.exec();
}

// Move skin between status indexes and merge field updates into the stored record
export async function moveSkinStatus(
  ck: string,
  from: SkinStatus,
  to: SkinStatus,
  updates: Partial<SkinRecord>,
): Promise<SkinRecord | null> {
  const existing = await getSkinRecord(ck);
  if (!existing) {
    return null;
  }

  const updated: SkinRecord = { ...existing, ...updates, status: to };

  const pipe = redis().pipeline();
  pipe.set(kvKey(ck), updated);
  pipe.srem(statusIndex(from), ck);
  pipe.sadd(statusIndex(to), ck);
  await pipe.exec();

  return updated;
}

// List skins by status (or "all"), sorted by created_at descending
export async function listSkinsByStatus(status: SkinStatus | "all"): Promise<SkinRecord[]> {
  const members = await redis().smembers(statusIndex(status));
  if (members.length === 0) {
    return [];
  }

  const pipe = redis().pipeline();
  for (const ck of members) {
    pipe.get<SkinRecord>(kvKey(ck));
  }
  const results = await pipe.exec();

  const records = (results as Array<SkinRecord | null>).filter((r): r is SkinRecord => r !== null);

  return records.sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
  );
}

// Check if a record exists
export async function skinExists(ck: string): Promise<boolean> {
  const count = await redis().exists(kvKey(ck));
  return count === 1;
}

// Update fields on an existing skin record (does not move status indexes)
export async function updateSkinRecord(
  ck: string,
  updates: Partial<SkinRecord>,
): Promise<SkinRecord | null> {
  const existing = await getSkinRecord(ck);
  if (!existing) return null;
  const updated: SkinRecord = { ...existing, ...updates };
  await redis().set(kvKey(ck), updated);
  return updated;
}
