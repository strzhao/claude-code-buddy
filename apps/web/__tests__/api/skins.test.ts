// @vitest-environment node
import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("@/lib/kv", () => ({
  listSkinsByStatus: vi.fn(),
}));

import { listSkinsByStatus } from "@/lib/kv";
import { GET } from "@/app/api/skins/route";
import type { SkinRecord } from "@/lib/types";

const mockListSkinsByStatus = vi.mocked(listSkinsByStatus);

function makeSkinRecord(overrides: Partial<SkinRecord> = {}): SkinRecord {
  return {
    id: "test-skin",
    name: "Test Skin",
    author: "tester",
    version: "1.0.0",
    status: "approved",
    manifest: {} as SkinRecord["manifest"],
    blob_url: "https://example.com/skin.zip",
    preview_blob_url: null,
    size: 1024,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("GET /api/skins", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should return approved skins as RemoteSkinEntry[]", async () => {
    const record = makeSkinRecord();
    mockListSkinsByStatus.mockResolvedValue([record]);

    const response = await GET();
    const data = await response.json();

    expect(mockListSkinsByStatus).toHaveBeenCalledWith("approved");
    expect(data).toHaveLength(1);
    expect(data[0]).toEqual({
      id: "test-skin",
      name: "Test Skin",
      author: "tester",
      version: "1.0.0",
      preview_url: null,
      download_url: "https://example.com/skin.zip",
      size: 1024,
    });
  });

  it("should deduplicate by id keeping latest version", async () => {
    const older = makeSkinRecord({
      version: "1.0.0",
      created_at: "2026-01-01T00:00:00Z",
    });
    const newer = makeSkinRecord({
      version: "2.0.0",
      created_at: "2026-06-01T00:00:00Z",
      blob_url: "https://example.com/skin-v2.zip",
    });
    mockListSkinsByStatus.mockResolvedValue([older, newer]);

    const response = await GET();
    const data = await response.json();

    expect(data).toHaveLength(1);
    expect(data[0].version).toBe("2.0.0");
  });

  it("should return empty array when no approved skins", async () => {
    mockListSkinsByStatus.mockResolvedValue([]);

    const response = await GET();
    const data = await response.json();

    expect(data).toEqual([]);
  });

  it("should set cache control headers", async () => {
    mockListSkinsByStatus.mockResolvedValue([]);

    const response = await GET();

    expect(response.headers.get("Cache-Control")).toContain("s-maxage=300");
  });

  it("should return 500 on internal error", async () => {
    mockListSkinsByStatus.mockRejectedValue(new Error("Redis down"));

    const response = await GET();

    expect(response.status).toBe(500);
    const data = await response.json();
    expect(data.error).toBe("Internal server error");
  });
});
