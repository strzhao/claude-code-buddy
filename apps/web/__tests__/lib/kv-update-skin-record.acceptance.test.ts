// @vitest-environment node
/**
 * 验收测试: kv.ts updateSkinRecord 函数
 *
 * 验证设计文档中声明的行为：
 * - kv.ts 添加 updateSkinRecord(ck, updates) 函数
 * - 支持局部字段更新（不影响 status 索引）
 * - 目标使用场景：修复 Dog 皮肤的 preview_blob_url 字段
 */
import { describe, it, expect, vi } from "vitest";

vi.mock("@upstash/redis", () => {
  const mockPipeline = {
    set: vi.fn().mockReturnThis(),
    exec: vi.fn().mockResolvedValue([]),
  };
  const instance = {
    get: vi.fn().mockResolvedValue(null),
    set: vi.fn().mockResolvedValue("OK"),
    pipeline: vi.fn(() => mockPipeline),
  };
  return {
    Redis: vi.fn(() => instance),
  };
});

describe("updateSkinRecord (acceptance)", () => {
  it("updateSkinRecord 函数应当从 @/lib/kv 导出", async () => {
    const kvModule = await import("@/lib/kv");
    expect(typeof kvModule.updateSkinRecord).toBe("function");
  });

  it("updateSkinRecord 签名接受两个参数: (ck: string, updates: Partial<SkinRecord>)", async () => {
    const { updateSkinRecord } = await import("@/lib/kv");
    // 函数应该接受两个参数
    expect(updateSkinRecord).toHaveLength(2);
  });

  it("updateSkinRecord 应当返回 Promise（异步函数）", async () => {
    const { updateSkinRecord, compositeKey } = await import("@/lib/kv");
    const ck = compositeKey("dog", "1.0.0");
    // 函数应当返回 Promise（可能 resolve 为 null 或 SkinRecord）
    const result = updateSkinRecord(ck, { preview_blob_url: "https://example.com/dog.png" });
    expect(result).toBeInstanceOf(Promise);
    // 等待 Promise 完成
    await result.catch(() => {});
  });

  it("updateSkinRecord 与 moveSkinStatus 是职责分离的独立函数", async () => {
    const kvModule = await import("@/lib/kv");

    // 两个函数都应存在
    expect(typeof kvModule.updateSkinRecord).toBe("function");
    expect(typeof kvModule.moveSkinStatus).toBe("function");

    // 是不同的函数引用
    expect(kvModule.updateSkinRecord).not.toBe(kvModule.moveSkinStatus);
  });

  it("当记录不存在时 updateSkinRecord 应当返回 null", async () => {
    const { updateSkinRecord, compositeKey } = await import("@/lib/kv");
    const ck = compositeKey("nonexistent", "9.9.9");
    // Redis.get mock 返回 null，所以 updateSkinRecord 应当返回 null
    const result = await updateSkinRecord(ck, { preview_blob_url: null });
    expect(result).toBeNull();
  });
});
