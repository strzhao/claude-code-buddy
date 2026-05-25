import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

import { compositeKey, skinExists, setSkinRecordNX } from "@/lib/kv";
import { uploadSkinZip, uploadPreviewImage, deleteSkinBlobs } from "@/lib/storage";
import { validateSkinZip, extractPreviewImage } from "@/lib/validation";
import { MAX_UPLOAD_SIZE } from "@/lib/constants";
import { errorResponse } from "@/lib/errors";
import type { SkinRecord, UploadResponse } from "@/lib/types";

export const maxDuration = 60;
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  let blobUploaded = false;
  let manifestId = "";
  let manifestVersion = "";

  try {
    const contentType = request.headers.get("content-type") ?? "";
    if (!contentType.includes("multipart/form-data")) {
      return errorResponse(400, "Expected multipart/form-data");
    }

    const formData = await request.formData();
    const file = formData.get("file");
    const authorOverride = formData.get("author");

    if (!file || !(file instanceof File)) {
      return errorResponse(400, "No file provided");
    }

    if (file.size > MAX_UPLOAD_SIZE) {
      return errorResponse(413, "File too large", `Max ${MAX_UPLOAD_SIZE} bytes`);
    }

    const buffer = await file.arrayBuffer();

    const validationResult = await validateSkinZip(buffer);
    if (!validationResult.valid) {
      return errorResponse(400, "Validation failed", validationResult.errors.join("; "));
    }

    const manifest = validationResult.manifest!;
    manifestId = manifest.id;
    manifestVersion = manifest.version;

    if (typeof authorOverride === "string" && authorOverride.trim() !== "") {
      manifest.author = authorOverride.trim();
    }

    const ck = compositeKey(manifest.id, manifest.version);
    const exists = await skinExists(ck);
    if (exists) {
      return errorResponse(409, "Skin already exists", `${manifest.id}:${manifest.version}`);
    }

    // Upload blob — track for cleanup on subsequent failure
    const blob_url = await uploadSkinZip(manifest.id, manifest.version, Buffer.from(buffer));
    blobUploaded = true;

    let preview_blob_url: string | null = null;
    if (manifest.preview_image) {
      const previewBuffer = await extractPreviewImage(buffer, manifest);
      if (previewBuffer) {
        preview_blob_url = await uploadPreviewImage(manifest.id, manifest.version, previewBuffer);
      }
    }

    const now = new Date().toISOString();
    const record: SkinRecord = {
      id: manifest.id,
      name: manifest.name,
      author: manifest.author,
      version: manifest.version,
      status: "pending",
      manifest,
      blob_url,
      preview_blob_url,
      size: file.size,
      created_at: now,
      updated_at: now,
    };

    const created = await setSkinRecordNX(record);
    if (!created) {
      // Race condition: another request created the record first — clean up our blob
      await deleteSkinBlobs(manifest.id, manifest.version).catch(() => {});
      return errorResponse(409, "Skin already exists", `${manifest.id}:${manifest.version}`);
    }

    const uploadResponse: UploadResponse = {
      success: true,
      skin: {
        id: record.id,
        name: record.name,
        status: record.status,
      },
    };

    return NextResponse.json(uploadResponse, { status: 201 });
  } catch (err) {
    console.error("[upload] error:", err instanceof Error ? err.message : err);
    // Clean up orphaned blob if upload succeeded but KV write failed
    if (blobUploaded && manifestId && manifestVersion) {
      await deleteSkinBlobs(manifestId, manifestVersion).catch(() => {});
    }
    return errorResponse(500, "Internal server error");
  }
}
