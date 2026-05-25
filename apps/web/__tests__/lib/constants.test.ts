import { describe, it, expect } from "vitest";
import {
  MAX_UPLOAD_SIZE,
  MAX_UNCOMPRESSED_SIZE,
  ZIP_BOMB_RATIO,
  REDIS_PREFIX,
  REDIS_INDEX_ALL,
  REDIS_INDEX_APPROVED,
  REDIS_INDEX_PENDING,
  REDIS_INDEX_REJECTED,
  BLOB_BASE_PATH,
  CACHE_MAX_AGE,
} from "@/lib/constants";

describe("constants", () => {
  it("should export MAX_UPLOAD_SIZE as 5 MB", () => {
    expect(MAX_UPLOAD_SIZE).toBe(5 * 1024 * 1024);
  });

  it("should export MAX_UNCOMPRESSED_SIZE as 50 MB", () => {
    expect(MAX_UNCOMPRESSED_SIZE).toBe(50 * 1024 * 1024);
  });

  it("should export ZIP_BOMB_RATIO as 100", () => {
    expect(ZIP_BOMB_RATIO).toBe(100);
  });

  it("should export Redis key prefixes as strings", () => {
    expect(REDIS_PREFIX).toBe("skin");
    expect(REDIS_INDEX_ALL).toBe("skin-ids");
    expect(REDIS_INDEX_APPROVED).toBe("skin-ids:approved");
    expect(REDIS_INDEX_PENDING).toBe("skin-ids:pending");
    expect(REDIS_INDEX_REJECTED).toBe("skin-ids:rejected");
  });

  it("should export BLOB_BASE_PATH", () => {
    expect(BLOB_BASE_PATH).toBe("skins");
  });

  it("should export CACHE_MAX_AGE as 300 seconds", () => {
    expect(CACHE_MAX_AGE).toBe(300);
  });
});
