#!/usr/bin/env node

import { program } from "commander";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, resolve } from "path";
import archiver from "archiver";
import { Writable } from "stream";

// --- Types (mirrored from src/lib/types.ts) ---

interface MenuBarConfig {
  walk_prefix: string;
  walk_frame_count: number;
  run_prefix: string;
  run_frame_count: number;
  idle_frame: string;
  directory: string;
}

interface SkinVariant {
  id: string;
  name: string;
  sprite_prefix: string;
  preview_image?: string;
  bed_names?: string[];
}

interface SkinPackManifest {
  id: string;
  name: string;
  author: string;
  version: string;
  preview_image?: string;
  sprite_prefix: string;
  sprite_faces_right?: boolean;
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

// --- Local validation (steps 4-9 from validation.ts, no JSZip) ---

interface ValidationResult {
  valid: boolean;
  manifest?: SkinPackManifest;
  errors: string[];
}

function validateManifestFields(manifest: SkinPackManifest): ValidationResult {
  const errors: string[] = [];

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
    if (typeof value !== "string" || (value as string).trim() === "") {
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
    if (!Array.isArray(value) || (value as unknown[]).length === 0) {
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
    const requiredMenuBarStrings: (keyof MenuBarConfig)[] = [
      "walk_prefix",
      "run_prefix",
      "idle_frame",
      "directory",
    ];
    for (const field of requiredMenuBarStrings) {
      const value = menu_bar[field];
      if (typeof value !== "string" || (value as string).trim() === "") {
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

  // Step 9: Format validation (id and version)
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

  if (errors.length > 0) {
    return { valid: false, errors };
  }

  return { valid: true, manifest, errors: [] };
}

// --- Zip into Buffer using archiver ---

async function zipDirectory(dirPath: string): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];

    const writable = new Writable({
      write(chunk: Buffer, _encoding: BufferEncoding, callback: () => void) {
        chunks.push(chunk);
        callback();
      },
    });

    writable.on("finish", () => {
      resolve(Buffer.concat(chunks));
    });

    writable.on("error", reject);

    const archive = archiver("zip", { zlib: { level: 9 } });

    archive.on("error", reject);

    archive.pipe(writable);
    archive.directory(dirPath, false);
    archive.finalize().catch(reject);
  });
}

// --- Upload command ---

async function uploadCommand(
  directory: string,
  options: { server: string; facing?: string },
): Promise<void> {
  const dirPath = resolve(directory);

  // Step 2: Read manifest.json
  const manifestPath = join(dirPath, "manifest.json");
  if (!existsSync(manifestPath)) {
    console.error(`Error: manifest.json not found in ${dirPath}`);
    process.exit(1);
  }

  // Step 3: Parse JSON
  let manifest: SkinPackManifest;
  try {
    const text = readFileSync(manifestPath, "utf-8");
    manifest = JSON.parse(text) as SkinPackManifest;
  } catch {
    console.error("Error: manifest.json is not valid JSON");
    process.exit(1);
  }

  // Apply --facing flag: write sprite_faces_right into manifest
  if (options.facing) {
    const facesRight = options.facing === "right";
    manifest.sprite_faces_right = facesRight;
    writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
    console.log(`Set sprite_faces_right=${facesRight} (sprites face ${options.facing})`);
  } else if (manifest.sprite_faces_right === undefined) {
    // Default: assume sprites face right
    console.log(
      "Tip: No --facing specified and no sprite_faces_right in manifest.\n" +
        "     Defaulting to right. Use --facing left if your sprites face left.\n" +
        "     How to tell: open your idle-a-1.png — the direction the character\n" +
        "     is looking/walking is its facing direction.",
    );
  }

  // Step 4-9: Local validation
  const validation = validateManifestFields(manifest);
  if (!validation.valid) {
    console.error("Validation errors:");
    for (const err of validation.errors) {
      console.error(`  - ${err}`);
    }
    process.exit(1);
  }

  // Step 8 (disk check): Key sprite file exists
  const keySpritePath = join(
    dirPath,
    manifest.sprite_directory,
    `${manifest.sprite_prefix}-idle-a-1.png`,
  );
  if (!existsSync(keySpritePath)) {
    const relPath = `${manifest.sprite_directory}/${manifest.sprite_prefix}-idle-a-1.png`;
    console.error(`Error: Key sprite not found: ${relPath}`);
    process.exit(1);
  }

  // Step 6: Zip directory
  console.log("Zipping skin pack...");
  let zipBuffer: Buffer;
  try {
    zipBuffer = await zipDirectory(dirPath);
  } catch (err) {
    console.error("Error: Failed to zip directory:", err);
    process.exit(1);
  }

  // Step 7: POST multipart form
  const serverUrl = options.server;
  const uploadUrl = `${serverUrl}/api/upload`;

  console.log(`Uploading to ${uploadUrl}...`);

  const formData = new FormData();
  const zipArrayBuffer = zipBuffer.buffer.slice(
    zipBuffer.byteOffset,
    zipBuffer.byteOffset + zipBuffer.byteLength,
  ) as ArrayBuffer;
  const zipBlob = new Blob([zipArrayBuffer], { type: "application/zip" });
  formData.append("file", zipBlob, `${manifest.id}.zip`);

  let response: Response;
  try {
    response = await fetch(uploadUrl, {
      method: "POST",
      body: formData,
    });
  } catch (err) {
    console.error("Error: Failed to connect to server:", err);
    process.exit(1);
  }

  // Step 8: Parse response
  if (response.status === 201) {
    let body: { skin?: { id: string; name: string; status: string } };
    try {
      body = (await response.json()) as typeof body;
    } catch {
      body = {};
    }
    const skin = body.skin;
    if (skin) {
      console.log(`✓ Uploaded "${skin.name}" (id: ${skin.id}, status: ${skin.status})`);
    } else {
      console.log("✓ Uploaded successfully");
    }
  } else if (response.status === 400) {
    let body: { error?: string; details?: string };
    try {
      body = (await response.json()) as typeof body;
    } catch {
      body = {};
    }
    console.error("Validation error from server:");
    if (body.error) console.error(`  ${body.error}`);
    if (body.details) console.error(`  ${body.details}`);
    process.exit(1);
  } else if (response.status === 409) {
    let body: { error?: string };
    try {
      body = (await response.json()) as typeof body;
    } catch {
      body = {};
    }
    console.error(`Duplicate skin pack: ${body.error ?? "A skin with this id already exists"}`);
    process.exit(1);
  } else if (response.status === 413) {
    console.error("Upload failed: Skin pack is too large (exceeds server size limit)");
    process.exit(1);
  } else {
    let body: { error?: string };
    try {
      body = (await response.json()) as typeof body;
    } catch {
      body = {};
    }
    console.error(`Server error (${response.status}): ${body.error ?? response.statusText}`);
    process.exit(1);
  }
}

// --- CLI setup ---

const DEFAULT_SERVER = process.env["SKIN_STORE_URL"] ?? "http://localhost:3000";

program
  .name("buddy-skin")
  .description("CLI tool for uploading skin packs to Claude Code Buddy store")
  .version("1.0.0");

program
  .command("upload <directory>")
  .description("Upload a skin pack directory to the store")
  .option("--server <url>", "Store API URL", DEFAULT_SERVER)
  .option(
    "--facing <direction>",
    "Sprite facing direction: 'left' or 'right'.\n" +
      "  Open your idle-a-1.png to check which way the character looks.\n" +
      "  - right (default): character faces right →\n" +
      "  - left: character faces left ←\n" +
      "  Sets sprite_faces_right in manifest.json automatically.",
  )
  .action((directory: string, options: { server: string; facing?: string }) => {
    if (options.facing && !["left", "right"].includes(options.facing)) {
      console.error("Error: --facing must be 'left' or 'right'");
      process.exit(1);
    }
    uploadCommand(directory, options).catch((err: unknown) => {
      console.error("Unexpected error:", err);
      process.exit(1);
    });
  });

program.parse();
