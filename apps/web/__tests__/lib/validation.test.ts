import { describe, it, expect } from "vitest";
import JSZip from "jszip";
import { validateSkinZip, extractPreviewImage } from "@/lib/validation";

function makeManifest(overrides: Record<string, unknown> = {}) {
  return {
    id: "test-skin",
    name: "Test Skin",
    author: "tester",
    version: "1.0.0",
    sprite_prefix: "buddy",
    animation_names: ["idle", "walk"],
    canvas_size: [128, 128],
    bed_names: ["bed1"],
    boundary_sprite: "boundary.png",
    food_names: ["food1"],
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
    ...overrides,
  };
}

async function makeZipBuffer(
  manifest: Record<string, unknown>,
  files: Record<string, string | Uint8Array> = {},
) {
  const zip = new JSZip();
  zip.file("manifest.json", JSON.stringify(manifest));
  // Add key sprite by default
  const spriteDir = (manifest.sprite_directory as string) || "sprites";
  const spritePrefix = (manifest.sprite_prefix as string) || "buddy";
  const keySpritePath = `${spriteDir}/${spritePrefix}-idle-a-1.png`;
  if (!files[keySpritePath]) {
    zip.file(keySpritePath, new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
  }
  for (const [path, content] of Object.entries(files)) {
    zip.file(path, content);
  }
  return zip.generateAsync({ type: "arraybuffer" });
}

describe("validateSkinZip", () => {
  it("should accept a valid zip with correct manifest", async () => {
    const manifest = makeManifest();
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.manifest).toBeDefined();
    expect(result.manifest!.id).toBe("test-skin");
  });

  it("should reject invalid zip data", async () => {
    const result = await validateSkinZip(new ArrayBuffer(10));
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("Invalid zip file");
  });

  it("should reject zip without manifest.json", async () => {
    const zip = new JSZip();
    zip.file("readme.txt", "hello");
    const buffer = await zip.generateAsync({ type: "arraybuffer" });
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("manifest.json not found in zip root");
  });

  it("should reject zip with invalid JSON manifest", async () => {
    const zip = new JSZip();
    zip.file("manifest.json", "not json{{{");
    const buffer = await zip.generateAsync({ type: "arraybuffer" });
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("manifest.json is not valid JSON");
  });

  it("should reject manifest missing required string fields", async () => {
    const manifest = makeManifest({ id: "" });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("id"))).toBe(true);
  });

  it("should reject manifest missing required array fields", async () => {
    const manifest = makeManifest({ animation_names: [] });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("animation_names"))).toBe(true);
  });

  it("should reject invalid canvas_size", async () => {
    const manifest = makeManifest({ canvas_size: [0, 128] });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("canvas_size"))).toBe(true);
  });

  it("should reject missing menu_bar", async () => {
    const manifest = makeManifest({ menu_bar: null });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("menu_bar"))).toBe(true);
  });

  it("should reject invalid id format", async () => {
    const manifest = makeManifest({ id: "-bad-id-" });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("id must match pattern"))).toBe(true);
  });

  it("should reject invalid version format", async () => {
    const manifest = makeManifest({ version: "1.0" });
    const buffer = await makeZipBuffer(manifest);
    const result = await validateSkinZip(buffer);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("version must match semver"))).toBe(true);
  });
});

describe("extractPreviewImage", () => {
  it("should return null when no preview_image in manifest", async () => {
    const manifest = makeManifest();
    const buffer = await makeZipBuffer(manifest);
    const result = await extractPreviewImage(buffer, manifest as never);
    expect(result).toBeNull();
  });

  it("should extract preview image when it exists", async () => {
    const pngData = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const manifest = makeManifest({ preview_image: "preview.png" });
    const buffer = await makeZipBuffer(manifest, {
      "sprites/preview.png": pngData,
    });
    const result = await extractPreviewImage(buffer, manifest as never);
    expect(result).not.toBeNull();
    expect(result!.length).toBeGreaterThan(0);
  });

  it("should return null when preview image file does not exist in zip", async () => {
    const manifest = makeManifest({ preview_image: "nonexistent.png" });
    const buffer = await makeZipBuffer(manifest);
    const result = await extractPreviewImage(buffer, manifest as never);
    expect(result).toBeNull();
  });
});
