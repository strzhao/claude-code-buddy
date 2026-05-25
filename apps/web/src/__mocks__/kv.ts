import { vi } from "vitest";

export const compositeKey = vi.fn((id: string, version: string) => `${id}:${version}`);

export const getSkinRecord = vi.fn().mockResolvedValue(null);

export const setSkinRecordNX = vi.fn().mockResolvedValue(true);

export const deleteSkinRecord = vi.fn().mockResolvedValue(undefined);

export const moveSkinStatus = vi.fn().mockResolvedValue(null);

export const listSkinsByStatus = vi.fn().mockResolvedValue([]);

export const skinExists = vi.fn().mockResolvedValue(false);
