import JSZip from "jszip";
import type { SkinPackManifest } from "./types";
import { MAX_UNCOMPRESSED_SIZE, ZIP_BOMB_RATIO } from "./constants";

export interface ValidationResult {
  valid: boolean;
  manifest?: SkinPackManifest;
  errors: string[];
}

export async function validateSkinZip(buffer: ArrayBuffer): Promise<ValidationResult> {
  const errors: string[] = [];

  // Step 1: Parse zip
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(buffer);
  } catch {
    return { valid: false, errors: ["Invalid zip file"] };
  }

  // Step 2: manifest.json exists
  const manifestFile = zip.file("manifest.json");
  if (!manifestFile) {
    return { valid: false, errors: ["manifest.json not found in zip root"] };
  }

  // Step 3: Parse JSON
  let manifest: SkinPackManifest;
  try {
    const text = await manifestFile.async("string");
    manifest = JSON.parse(text) as SkinPackManifest;
  } catch {
    return { valid: false, errors: ["manifest.json is not valid JSON"] };
  }

  // Step 4: Required string fields
  const requiredStringFields: (keyof SkinPackManifest)[] = [
    "id",
    "name",
    "author",
    "version",
    "sprite_prefix",
    "boundary_sprite",
    "food_directory",
    "sprite_directory",
  ];
  for (const field of requiredStringFields) {
    const value = manifest[field];
    if (typeof value !== "string" || value.trim() === "") {
      errors.push(`manifest.json missing or empty required field: ${field}`);
    }
  }

  // Step 5: Required array fields
  const requiredArrayFields: (keyof SkinPackManifest)[] = [
    "animation_names",
    "bed_names",
    "food_names",
  ];
  for (const field of requiredArrayFields) {
    const value = manifest[field];
    if (!Array.isArray(value) || value.length === 0) {
      errors.push(`manifest.json missing or empty required array field: ${field}`);
    }
  }

  // Step 6: canvas_size must be exactly 2-element array of positive numbers
  const { canvas_size } = manifest;
  if (
    !Array.isArray(canvas_size) ||
    canvas_size.length !== 2 ||
    typeof canvas_size[0] !== "number" ||
    typeof canvas_size[1] !== "number" ||
    canvas_size[0] <= 0 ||
    canvas_size[1] <= 0
  ) {
    errors.push("manifest.json canvas_size must be a 2-element array of positive numbers");
  }

  // Step 7: menu_bar object validation
  const { menu_bar } = manifest;
  if (!menu_bar || typeof menu_bar !== "object") {
    errors.push("manifest.json missing required field: menu_bar");
  } else {
    const requiredMenuBarStrings: (keyof typeof menu_bar)[] = [
      "walk_prefix",
      "run_prefix",
      "idle_frame",
      "directory",
    ];
    for (const field of requiredMenuBarStrings) {
      const value = menu_bar[field];
      if (typeof value !== "string" || value.trim() === "") {
        errors.push(`manifest.json menu_bar missing or empty required field: ${field}`);
      }
    }

    if (
      typeof menu_bar.walk_frame_count !== "number" ||
      !Number.isInteger(menu_bar.walk_frame_count) ||
      menu_bar.walk_frame_count <= 0
    ) {
      errors.push("manifest.json menu_bar.walk_frame_count must be a positive integer");
    }

    if (
      typeof menu_bar.run_frame_count !== "number" ||
      !Number.isInteger(menu_bar.run_frame_count) ||
      menu_bar.run_frame_count <= 0
    ) {
      errors.push("manifest.json menu_bar.run_frame_count must be a positive integer");
    }
  }

  // Return early if structural errors prevent further checks
  if (errors.length > 0) {
    return { valid: false, errors };
  }

  // Step 8: Key sprite exists
  const keySpritePath = `${manifest.sprite_directory}/${manifest.sprite_prefix}-idle-a-1.png`;
  if (!zip.file(keySpritePath)) {
    errors.push(`Key sprite not found in zip: ${keySpritePath}`);
  }

  // Step 9: Format validation
  const idPattern = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/i;
  if (!idPattern.test(manifest.id)) {
    errors.push(
      "manifest.json id must match pattern: letters, digits, hyphens (no leading/trailing hyphens)",
    );
  }

  const versionPattern = /^\d+\.\d+\.\d+$/;
  if (!versionPattern.test(manifest.version)) {
    errors.push("manifest.json version must match semver pattern: X.Y.Z (digits only)");
  }

  // Step 9.5: Validate variants (optional field)
  if (manifest.variants !== undefined) {
    if (!Array.isArray(manifest.variants)) {
      errors.push("manifest.json variants must be an array if provided");
    } else {
      const variantIds = new Set<string>();
      for (const variant of manifest.variants) {
        const hasId = typeof variant.id === "string" && variant.id.trim() !== "";
        const hasName = typeof variant.name === "string" && variant.name.trim() !== "";
        const hasPrefix =
          typeof variant.sprite_prefix === "string" && variant.sprite_prefix.trim() !== "";

        if (!hasId) errors.push("variant missing required field: id");
        if (!hasName) errors.push("variant missing required field: name");
        if (!hasPrefix) errors.push("variant missing required field: sprite_prefix");

        if (!hasId || !hasPrefix) continue;

        if (variantIds.has(variant.id)) {
          errors.push(`duplicate variant id: ${variant.id}`);
        }
        variantIds.add(variant.id);

        // Validate that at least the idle sprite exists for this variant
        const variantSpritePath = `${manifest.sprite_directory}/${variant.sprite_prefix}-idle-a-1.png`;
        if (!zip.file(variantSpritePath)) {
          errors.push(`Variant "${variant.id}" key sprite not found: ${variantSpritePath}`);
        }

        if (variant.bed_names !== undefined) {
          if (!Array.isArray(variant.bed_names) || variant.bed_names.length === 0) {
            errors.push(`variant "${variant.id}" bed_names must be a non-empty array if provided`);
          }
        }
      }
    }
  }

  // Step 10: Zip bomb protection
  let totalUncompressedSize = 0;
  const zipFiles = zip.files;

  for (const filename of Object.keys(zipFiles)) {
    const file = zipFiles[filename];
    if (file.dir) continue;

    // Get uncompressed size by reading the file data
    // JSZip exposes _data internally; use it if available, else decompress
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fileData = (file as any)._data;
    let uncompressedSize: number;
    let compressedSize: number;

    if (
      fileData &&
      typeof fileData.uncompressedSize === "number" &&
      typeof fileData.compressedSize === "number"
    ) {
      uncompressedSize = fileData.uncompressedSize;
      compressedSize = fileData.compressedSize;

      if (compressedSize > 0 && uncompressedSize / compressedSize > ZIP_BOMB_RATIO) {
        errors.push(`Zip bomb detected: file "${filename}" has suspicious compression ratio`);
        return { valid: false, errors };
      }
    } else {
      // Fallback: decompress to get size (less efficient but safe)
      const content = await file.async("arraybuffer");
      uncompressedSize = content.byteLength;
    }

    totalUncompressedSize += uncompressedSize;

    if (totalUncompressedSize > MAX_UNCOMPRESSED_SIZE) {
      errors.push(`Total uncompressed size exceeds limit of ${MAX_UNCOMPRESSED_SIZE} bytes`);
      return { valid: false, errors };
    }
  }

  if (errors.length > 0) {
    return { valid: false, errors };
  }

  return { valid: true, manifest, errors: [] };
}

export async function extractPreviewImage(
  buffer: ArrayBuffer,
  manifest: SkinPackManifest,
): Promise<Buffer | null> {
  if (!manifest.preview_image) {
    return null;
  }

  // Sanitize path components to prevent traversal within zip
  const safeDir = manifest.sprite_directory.replace(/\.\./g, "").replace(/^\//, "");
  const safeImage = manifest.preview_image.replace(/\.\./g, "").replace(/^\//, "");
  if (!safeDir || !safeImage) {
    return null;
  }

  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(buffer);
  } catch {
    return null;
  }

  const previewPath = `${safeDir}/${safeImage}`;
  const previewFile = zip.file(previewPath);
  if (!previewFile) {
    return null;
  }

  try {
    const data = await previewFile.async("nodebuffer");
    return data;
  } catch {
    return null;
  }
}
