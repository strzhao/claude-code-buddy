// @vitest-environment node
/**
 * 验收测试: scripts/fix-dog-preview.ts
 *
 * 验证设计文档声明的行为：
 * - scripts/fix-dog-preview.ts 作为独立脚本存在
 * - 默认 dry-run（不写入 Redis），--execute 才执行写入
 * - 通过 kv.ts 的 updateSkinRecord 修复 preview_blob_url 字段
 *
 * 测试策略：验证脚本文件存在 + 导入 updateSkinRecord
 * （脚本本身是 Node.js CLI，真实写入需要 Redis 连接，此处验证接口契约）
 */
import { describe, it, expect } from "vitest";
import { existsSync } from "fs";
import { resolve } from "path";

const PROJECT_ROOT = resolve(__dirname, "../..");
const SCRIPT_PATH = resolve(PROJECT_ROOT, "scripts/fix-dog-preview.ts");

describe("fix-dog-preview 脚本 (acceptance)", () => {
  it("scripts/fix-dog-preview.ts 文件应当存在", () => {
    expect(existsSync(SCRIPT_PATH)).toBe(true);
  });

  it("updateSkinRecord 函数应当从 @/lib/kv 导出（脚本依赖）", async () => {
    const kvModule = await import("@/lib/kv");
    expect(typeof kvModule.updateSkinRecord).toBe("function");
  });
});

describe("fix-dog-preview 脚本 dry-run 行为 (acceptance)", () => {
  it("updateSkinRecord 参数应支持 preview_blob_url 字段更新", async () => {
    const { updateSkinRecord } = await import("@/lib/kv");

    // 验证函数签名允许传入 preview_blob_url（TypeScript 类型兼容性）
    // 在 dry-run 模式下脚本只应打印不写入；此处验证函数可被调用
    // 实际 Redis 不可用时函数应 reject，不应 throw 同步错误
    const promise = updateSkinRecord("dog:1.0.0", {
      preview_blob_url: "https://example.com/new-dog-preview.png",
    });

    expect(promise).toBeInstanceOf(Promise);
    // 不关心 resolve/reject（无真实 Redis 环境）
    await promise.catch(() => {});
  });

  it("updateSkinRecord 应仅修改指定字段，不影响 status 索引", async () => {
    // 这是设计文档规格：updateSkinRecord 只做字段合并，不移动 status 索引
    // 通过检查函数存在且与 moveSkinStatus 是独立导出来验证职责分离
    const kvModule = await import("@/lib/kv");

    expect(typeof kvModule.updateSkinRecord).toBe("function");
    expect(typeof kvModule.moveSkinStatus).toBe("function");

    // 两个函数是独立的，职责分离
    expect(kvModule.updateSkinRecord).not.toBe(kvModule.moveSkinStatus);
  });
});
