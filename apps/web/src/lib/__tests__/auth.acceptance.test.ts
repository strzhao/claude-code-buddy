/**
 * 验收测试：auth 工具库
 *
 * 黑盒测试 src/lib/auth.ts 导出的以下契约：
 *   - createGatewaySession(email): Promise<string> | string
 *     创建 HMAC-SHA256 签名的 gateway session cookie value（secret 从 AUTH_GATEWAY_SESSION_SECRET 环境变量读取）
 *   - verifyGatewaySession(cookieValue): Promise<GatewaySessionPayload | null> | GatewaySessionPayload | null
 *     验证并解析 cookie；过期或篡改返回 null（secret 从环境变量读取）
 *   - isAdminEmail(email, adminEmailsEnv?): boolean
 *     检查 email 是否在管理员列表中（列表来自参数或 AUTH_ADMIN_EMAILS 环境变量）
 *
 * Cookie 格式：base64url(JSON payload) + "." + base64url(HMAC-SHA256 signature)
 * Payload：{ email, issuedAt, expiresAt }（issuedAt/expiresAt 为 ISO 8601 字符串或 ms 时间戳）
 * TTL：12 小时
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { createHmac } from "crypto";

// ---- 被测函数类型定义（宽松类型，兼容同步/异步实现）----
type GatewaySessionPayload = {
  email: string;
  issuedAt: string | number;
  expiresAt: string | number;
};

type AuthModule = {
  createGatewaySession: (email: string) => Promise<string> | string;
  verifyGatewaySession: (
    cookieValue: string,
  ) => Promise<GatewaySessionPayload | null> | GatewaySessionPayload | null;
  isAdminEmail: (email: string, adminEmailsEnv?: string) => boolean;
};

const TEST_SECRET = "test-secret-at-least-32-chars-long-!!";
const ADMIN_EMAIL = "admin@example.com";

// ---- 设置/清理环境变量 ----
let originalEnv: NodeJS.ProcessEnv;
beforeEach(() => {
  originalEnv = { ...process.env };
  process.env.AUTH_GATEWAY_SESSION_SECRET = TEST_SECRET;
  process.env.AUTH_ADMIN_EMAILS = ADMIN_EMAIL;
});

afterEach(() => {
  Object.keys(process.env).forEach((k) => delete process.env[k]);
  Object.assign(process.env, originalEnv);
  vi.resetModules();
});

// ---- 动态导入（每次 resetModules 后重新导入）----
async function loadAuth(): Promise<AuthModule> {
  return (await import("@/lib/auth")) as AuthModule;
}

// ---- 辅助：手工按协议构造 cookie（不依赖被测实现）----
function buildCookieManually(
  payload: Record<string, unknown>,
  secret: string,
  overrideSignature?: string,
): string {
  const payloadB64 = Buffer.from(JSON.stringify(payload))
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
  const sig =
    overrideSignature ??
    createHmac("sha256", secret)
      .update(payloadB64)
      .digest("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");
  return `${payloadB64}.${sig}`;
}

// ============================================================
// createGatewaySession
// ============================================================
describe("auth 工具库 — createGatewaySession", () => {
  it("返回包含一个点分隔符的字符串（payload.signature 格式）", async () => {
    const { createGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    expect(typeof cookie).toBe("string");
    expect(cookie).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  });

  it("payload 部分解码后包含正确的 email 字段", async () => {
    const { createGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const [payloadB64] = cookie.split(".");
    const payload = JSON.parse(Buffer.from(payloadB64, "base64").toString("utf-8"));
    expect(payload.email).toBe(ADMIN_EMAIL);
  });

  it("payload 包含 issuedAt 和 expiresAt 字段", async () => {
    const { createGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const [payloadB64] = cookie.split(".");
    const payload = JSON.parse(Buffer.from(payloadB64, "base64").toString("utf-8"));
    expect(payload.issuedAt).toBeDefined();
    expect(payload.expiresAt).toBeDefined();
  });

  it("expiresAt 比 issuedAt 晚恰好约 12 小时（允许 ±60 秒误差）", async () => {
    const { createGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const [payloadB64] = cookie.split(".");
    const payload = JSON.parse(Buffer.from(payloadB64, "base64").toString("utf-8"));
    const issuedMs =
      typeof payload.issuedAt === "number"
        ? payload.issuedAt
        : new Date(payload.issuedAt).getTime();
    const expiresMs =
      typeof payload.expiresAt === "number"
        ? payload.expiresAt
        : new Date(payload.expiresAt).getTime();
    const ttlMs = expiresMs - issuedMs;
    const TWELVE_HOURS_MS = 12 * 60 * 60 * 1000;
    const TOLERANCE_MS = 60 * 1000;
    expect(Math.abs(ttlMs - TWELVE_HOURS_MS)).toBeLessThanOrEqual(TOLERANCE_MS);
  });

  it("两次调用的 payload email 字段一致", async () => {
    const { createGatewaySession } = await loadAuth();
    const c1 = await createGatewaySession(ADMIN_EMAIL);
    const c2 = await createGatewaySession(ADMIN_EMAIL);
    const p1 = JSON.parse(Buffer.from(c1.split(".")[0], "base64").toString());
    const p2 = JSON.parse(Buffer.from(c2.split(".")[0], "base64").toString());
    expect(p1.email).toBe(p2.email);
  });
});

// ============================================================
// verifyGatewaySession — 有效 session
// ============================================================
describe("auth 工具库 — verifyGatewaySession：有效 session", () => {
  it("返回包含 email 的 payload 对象", async () => {
    const { createGatewaySession, verifyGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const result = await verifyGatewaySession(cookie);
    expect(result).not.toBeNull();
    expect(result!.email).toBe(ADMIN_EMAIL);
  });

  it("返回的 payload 包含 issuedAt 和 expiresAt", async () => {
    const { createGatewaySession, verifyGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const result = await verifyGatewaySession(cookie);
    expect(result!.issuedAt).toBeDefined();
    expect(result!.expiresAt).toBeDefined();
  });
});

// ============================================================
// verifyGatewaySession — 篡改检测
// ============================================================
describe("auth 工具库 — verifyGatewaySession：篡改检测", () => {
  it("签名被修改后返回 null", async () => {
    const { createGatewaySession, verifyGatewaySession } = await loadAuth();
    const cookie = await createGatewaySession(ADMIN_EMAIL);
    const [payloadB64] = cookie.split(".");
    const tampered = `${payloadB64}.invalidsignatureXXX`;
    expect(await verifyGatewaySession(tampered)).toBeNull();
  });

  it("payload 被篡改（用错误 secret 签名）返回 null", async () => {
    const { verifyGatewaySession } = await loadAuth();
    const fakePayload = {
      email: "hacker@evil.com",
      issuedAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 12 * 3600 * 1000).toISOString(),
    };
    // 用错误的 secret 构造 cookie，然后用正确的环境变量 secret 验证
    const cookie = buildCookieManually(fakePayload, "wrong-secret-xxx");
    expect(await verifyGatewaySession(cookie)).toBeNull();
  });

  it("cookie 格式完全错误（无点分隔）返回 null", async () => {
    const { verifyGatewaySession } = await loadAuth();
    expect(await verifyGatewaySession("notacookieatall")).toBeNull();
  });

  it("空字符串返回 null", async () => {
    const { verifyGatewaySession } = await loadAuth();
    expect(await verifyGatewaySession("")).toBeNull();
  });
});

// ============================================================
// verifyGatewaySession — 过期检测
// ============================================================
describe("auth 工具库 — verifyGatewaySession：过期检测", () => {
  it("expiresAt 已过去的 cookie 返回 null", async () => {
    const { verifyGatewaySession } = await loadAuth();
    const expiredPayload = {
      email: ADMIN_EMAIL,
      issuedAt: new Date(Date.now() - 13 * 3600 * 1000).toISOString(),
      expiresAt: new Date(Date.now() - 1 * 3600 * 1000).toISOString(), // 1 小时前过期
    };
    // 用当前环境变量的 secret 构造一个合法但已过期的 cookie
    const cookie = buildCookieManually(expiredPayload, TEST_SECRET);
    expect(await verifyGatewaySession(cookie)).toBeNull();
  });

  it("expiresAt 在未来的手工构造 cookie 正常返回 payload", async () => {
    const { verifyGatewaySession } = await loadAuth();
    const validPayload = {
      email: ADMIN_EMAIL,
      issuedAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 11 * 3600 * 1000).toISOString(),
    };
    const cookie = buildCookieManually(validPayload, TEST_SECRET);
    const result = await verifyGatewaySession(cookie);
    expect(result).not.toBeNull();
    expect(result!.email).toBe(ADMIN_EMAIL);
  });
});

// ============================================================
// isAdminEmail
// ============================================================
describe("auth 工具库 — isAdminEmail", () => {
  it("精确匹配环境变量中的管理员邮箱返回 true", async () => {
    process.env.AUTH_ADMIN_EMAILS = "admin@example.com";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("admin@example.com")).toBe(true);
  });

  it("不在管理员列表中的邮箱返回 false", async () => {
    process.env.AUTH_ADMIN_EMAILS = "admin@example.com";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("user@example.com")).toBe(false);
  });

  it("逗号分隔多个邮箱，第一个匹配返回 true", async () => {
    process.env.AUTH_ADMIN_EMAILS = "alice@example.com,bob@example.com";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("alice@example.com")).toBe(true);
  });

  it("逗号分隔多个邮箱，第二个匹配返回 true", async () => {
    process.env.AUTH_ADMIN_EMAILS = "alice@example.com,bob@example.com";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("bob@example.com")).toBe(true);
  });

  it("列表中条目前后有空白时仍能正确匹配（trim）", async () => {
    process.env.AUTH_ADMIN_EMAILS = " admin@example.com , other@example.com ";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("admin@example.com")).toBe(true);
  });

  it("AUTH_ADMIN_EMAILS 为空时，任何邮箱都返回 false", async () => {
    process.env.AUTH_ADMIN_EMAILS = "";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("admin@example.com")).toBe(false);
  });

  it("AUTH_ADMIN_EMAILS 仅包含空白时，任何邮箱都返回 false", async () => {
    process.env.AUTH_ADMIN_EMAILS = "  ,  ,  ";
    vi.resetModules();
    const { isAdminEmail } = await loadAuth();
    expect(isAdminEmail("admin@example.com")).toBe(false);
  });
});

// ============================================================
// 跨系统数据流验证（核心集成用例）
// ============================================================
describe("auth 工具库 — 跨系统数据流（Session 创建到验证）", () => {
  it("[端到端] createGatewaySession 创建的 cookie 能被 verifyGatewaySession 验证通过并提取相同邮箱", async () => {
    const { createGatewaySession, verifyGatewaySession } = await loadAuth();
    const originalEmail = "integration@test.com";
    const cookie = await createGatewaySession(originalEmail);
    const payload = await verifyGatewaySession(cookie);
    expect(payload).not.toBeNull();
    expect(payload!.email).toBe(originalEmail);
  });

  it("[端到端] 用错误 secret 签名的 cookie 无法被正确 secret 验证（密钥隔离）", async () => {
    const { verifyGatewaySession } = await loadAuth();
    // 用与环境变量不同的 secret 手工构造 cookie
    const payload = {
      email: ADMIN_EMAIL,
      issuedAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 12 * 3600 * 1000).toISOString(),
    };
    const cookie = buildCookieManually(payload, "completely-different-secret-xxx");
    expect(await verifyGatewaySession(cookie)).toBeNull();
  });
});
