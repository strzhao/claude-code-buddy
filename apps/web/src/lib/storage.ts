import { put, del, list } from "@vercel/blob";
import { BLOB_BASE_PATH } from "./constants";

// Upload a skin pack zip file. Returns the blob URL.
export async function uploadSkinZip(id: string, version: string, buffer: Buffer): Promise<string> {
  const pathname = `${BLOB_BASE_PATH}/${id}/${version}/skin.zip`;
  const blob = await put(pathname, buffer, { access: "public" });
  return blob.url;
}

// Upload a preview image. Returns the blob URL.
export async function uploadPreviewImage(
  id: string,
  version: string,
  buffer: Buffer,
): Promise<string> {
  const pathname = `${BLOB_BASE_PATH}/${id}/${version}/preview.png`;
  const blob = await put(pathname, buffer, { access: "public" });
  return blob.url;
}

// Delete all blobs for a skin (zip + preview if exists)
export async function deleteSkinBlobs(id: string, version: string): Promise<void> {
  const prefix = `${BLOB_BASE_PATH}/${id}/${version}/`;
  const { blobs } = await list({ prefix });
  if (blobs.length > 0) {
    await del(blobs.map((b) => b.url));
  }
}
