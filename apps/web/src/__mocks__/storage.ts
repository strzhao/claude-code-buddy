import { vi } from "vitest";

export const uploadSkinZip = vi.fn().mockResolvedValue("https://blob.example.com/skin.zip");

export const uploadPreviewImage = vi.fn().mockResolvedValue("https://blob.example.com/preview.png");

export const deleteSkinBlobs = vi.fn().mockResolvedValue(undefined);
