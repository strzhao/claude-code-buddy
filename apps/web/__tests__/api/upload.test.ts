// @vitest-environment node
import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("@/lib/kv", () => ({
  compositeKey: vi.fn((id: string, version: string) => `${id}:${version}`),
  skinExists: vi.fn(),
  setSkinRecordNX: vi.fn(),
}));

vi.mock("@/lib/storage", () => ({
  uploadSkinZip: vi.fn(),
  uploadPreviewImage: vi.fn(),
  deleteSkinBlobs: vi.fn(),
}));

vi.mock("@/lib/validation", () => ({
  validateSkinZip: vi.fn(),
  extractPreviewImage: vi.fn(),
}));

import { skinExists, setSkinRecordNX } from "@/lib/kv";
import { uploadSkinZip } from "@/lib/storage";
import { validateSkinZip, extractPreviewImage } from "@/lib/validation";
import { POST } from "@/app/api/upload/route";
import type { NextRequest } from "next/server";

const mockSkinExists = vi.mocked(skinExists);
const mockSetSkinRecordNX = vi.mocked(setSkinRecordNX);
const mockUploadSkinZip = vi.mocked(uploadSkinZip);
const mockValidateSkinZip = vi.mocked(validateSkinZip);
const mockExtractPreviewImage = vi.mocked(extractPreviewImage);

function makeUploadRequest(file?: File, author?: string): NextRequest {
  const formData = new FormData();
  if (file) {
    formData.append("file", file);
  }
  if (author) {
    formData.append("author", author);
  }
  return new Request("http://localhost:3000/api/upload", {
    method: "POST",
    body: formData,
  }) as unknown as NextRequest;
}

describe("POST /api/upload", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should reject non-multipart requests", async () => {
    const request = new Request("http://localhost:3000/api/upload", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    }) as unknown as NextRequest;

    const response = await POST(request);
    expect(response.status).toBe(400);
    const data = await response.json();
    expect(data.error).toBe("Expected multipart/form-data");
  });

  it("should reject request without file", async () => {
    const request = makeUploadRequest();
    const response = await POST(request);
    expect(response.status).toBe(400);
    const data = await response.json();
    expect(data.error).toBe("No file provided");
  });

  it("should reject files exceeding size limit", async () => {
    const largeFile = new File([new ArrayBuffer(6 * 1024 * 1024)], "skin.zip", {
      type: "application/zip",
    });
    const request = makeUploadRequest(largeFile);
    const response = await POST(request);
    expect(response.status).toBe(413);
  });

  it("should reject invalid zip content", async () => {
    const file = new File([new ArrayBuffer(100)], "skin.zip", {
      type: "application/zip",
    });
    mockValidateSkinZip.mockResolvedValue({
      valid: false,
      errors: ["Invalid zip file"],
    });

    const request = makeUploadRequest(file);
    const response = await POST(request);
    expect(response.status).toBe(400);
    const data = await response.json();
    expect(data.error).toBe("Validation failed");
  });

  it("should reject duplicate skin uploads", async () => {
    const file = new File([new ArrayBuffer(100)], "skin.zip", {
      type: "application/zip",
    });
    mockValidateSkinZip.mockResolvedValue({
      valid: true,
      manifest: {
        id: "test-skin",
        version: "1.0.0",
        name: "Test",
        author: "tester",
        sprite_prefix: "buddy",
        animation_names: ["idle"],
        canvas_size: [128, 128] as [number, number],
        bed_names: ["bed"],
        boundary_sprite: "boundary.png",
        food_names: ["food"],
        food_directory: "food",
        sprite_directory: "sprites",
        menu_bar: {
          walk_prefix: "walk",
          walk_frame_count: 4,
          run_prefix: "run",
          run_frame_count: 4,
          idle_frame: "idle.png",
          directory: "menubar",
        },
      },
      errors: [],
    });
    mockSkinExists.mockResolvedValue(true);

    const request = makeUploadRequest(file);
    const response = await POST(request);
    expect(response.status).toBe(409);
  });

  it("should successfully upload a valid skin", async () => {
    const file = new File([new ArrayBuffer(100)], "skin.zip", {
      type: "application/zip",
    });
    mockValidateSkinZip.mockResolvedValue({
      valid: true,
      manifest: {
        id: "test-skin",
        version: "1.0.0",
        name: "Test",
        author: "tester",
        sprite_prefix: "buddy",
        animation_names: ["idle"],
        canvas_size: [128, 128] as [number, number],
        bed_names: ["bed"],
        boundary_sprite: "boundary.png",
        food_names: ["food"],
        food_directory: "food",
        sprite_directory: "sprites",
        menu_bar: {
          walk_prefix: "walk",
          walk_frame_count: 4,
          run_prefix: "run",
          run_frame_count: 4,
          idle_frame: "idle.png",
          directory: "menubar",
        },
      },
      errors: [],
    });
    mockSkinExists.mockResolvedValue(false);
    mockUploadSkinZip.mockResolvedValue("https://blob.example.com/skin.zip");
    mockExtractPreviewImage.mockResolvedValue(null);
    mockSetSkinRecordNX.mockResolvedValue(true);

    const request = makeUploadRequest(file);
    const response = await POST(request);
    expect(response.status).toBe(201);
    const data = await response.json();
    expect(data.success).toBe(true);
    expect(data.skin.id).toBe("test-skin");
  });
});
