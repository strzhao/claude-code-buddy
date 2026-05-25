/**
 * 验收测试：Middleware 鉴权逻辑
 *
 * 黑盒测试 middleware.ts 的行为契约：
 *   - 匹配路径：/admin/:path* 和 /api/admin/:path*
 *   - 公共路由（/、/upload、/api/skins、/api/upload）不受中间件拦截
 *   - /admin 页面路由无有效 session → 302 重定向到 /api/auth/login
 *   - /api/admin/* API 路由无有效 session → 401 JSON { error: "unauthorized" }
 *   - 非管理员邮箱的有效 session → 403
 *   - 过期 session → 拒绝（页面 302，API 401）
 *   - 有效管理员 session → NextResponse.next()（放行）
 *
 * 测试策略：
 *   直接调用 middleware 函数，mock NextRequest；
 *   通过 process.env 注入环境变量。
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// ---- 辅助：构造带 cookie 的 mock NextRequest ----
function makeMockRequest(
  pathname: string,
  cookieValue?: string,
): Parameters<(typeof import("../../middleware"))["middleware"]>[0] {
  const url = `http://localhost:3000${pathname}`;
  // 模拟 NextRequest 的最小接口
  const headers = new Headers();
  const cookieMap = new Map<string, { value: string }>();
  if (cookieValue !== undefined) {
    cookieMap.set("buddy_gateway_session", { value: cookieValue });
  }
  return {
    url,
    nextUrl: new URL(url),
    cookies: {
      get: (name: string) => cookieMap.get(name),
      has: (name: string) => cookieMap.has(name),
    },
    headers,
    method: "GET",
  } as unknown as Parameters<(typeof import("../../middleware"))["middleware"]>[0];
}

// ---- 辅助：用真实 HMAC 构造有效/无效 cookie ----
async function buildValidSessionCookie(
  email: string,
  secret: string,
  offsetMs = 0,
): Promise<string> {
  const { createHmac } = await import("crypto");
  const payload = {
    email,
    issuedAt: new Date(Date.now() + offsetMs).toISOString(),
    expiresAt: new Date(Date.now() + offsetMs + 12 * 3600 * 1000).toISOString(),
  };
  const payloadB64 = Buffer.from(JSON.stringify(payload))
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
  const sig = createHmac("sha256", secret)
    .update(payloadB64)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
  return `${payloadB64}.${sig}`;
}

async function buildExpiredSessionCookie(email: string, secret: string): Promise<string> {
  const { createHmac } = await import("crypto");
  const payload = {
    email,
    issuedAt: new Date(Date.now() - 13 * 3600 * 1000).toISOString(),
    expiresAt: new Date(Date.now() - 1 * 3600 * 1000).toISOString(), // 已过期
  };
  const payloadB64 = Buffer.from(JSON.stringify(payload))
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
  const sig = createHmac("sha256", secret)
    .update(payloadB64)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
  return `${payloadB64}.${sig}`;
}

// 测试使用的环境变量常量
const TEST_SECRET = "middleware-test-secret-32chars-xxx!!";
const ADMIN_EMAIL = "admin@stringzhao.life";
const NON_ADMIN_EMAIL = "regular@user.com";

// ---- 设置/清理环境变量 ----
let originalEnv: NodeJS.ProcessEnv;
beforeEach(() => {
  originalEnv = { ...process.env };
  process.env.AUTH_GATEWAY_SESSION_SECRET = TEST_SECRET;
  process.env.AUTH_ADMIN_EMAILS = ADMIN_EMAIL;
  process.env.APP_BASE_URL = "http://localhost:3000";
});

afterEach(() => {
  process.env = originalEnv;
  vi.resetModules();
});

// ---- 动态导入 middleware（每次测试后 resetModules 保证环境变量生效）----
async function loadMiddleware() {
  const mod = await import("../../middleware");
  return mod.middleware;
}

// ============================================================
// matcher 配置验证（验证 Next.js middleware 的路径匹配规则）
// ============================================================
describe("middleware — matcher 配置", () => {
  it("config.matcher 包含 /admin/:path* 规则", async () => {
    const mod = await import("../../middleware");
    const matcher = mod.config?.matcher;
    expect(Array.isArray(matcher)).toBe(true);
    const matchers = matcher as string[];
    expect(matchers.some((m) => m.startsWith("/admin"))).toBe(true);
  });

  it("config.matcher 包含 /api/admin/:path* 规则", async () => {
    const mod = await import("../../middleware");
    const matcher = mod.config?.matcher;
    const matchers = matcher as string[];
    expect(matchers.some((m) => m.startsWith("/api/admin"))).toBe(true);
  });

  it("config.matcher 不包含 /api/skins（公共接口不受保护）", async () => {
    const mod = await import("../../middleware");
    const matcher = mod.config?.matcher;
    const matchers = matcher as string[];
    expect(matchers.some((m) => m === "/api/skins" || m === "/api/skins/:path*")).toBe(false);
  });

  it("config.matcher 不包含 /api/upload（公共接口不受保护）", async () => {
    const mod = await import("../../middleware");
    const matcher = mod.config?.matcher;
    const matchers = matcher as string[];
    expect(matchers.some((m) => m === "/api/upload" || m === "/api/upload/:path*")).toBe(false);
  });
});

// ============================================================
// /admin 页面路由
// ============================================================
describe("middleware — /admin 页面路由：无有效 session", () => {
  it("无 cookie 时返回 302", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/admin");
    const res = await middleware(req);
    expect(res.status).toBe(302);
  });

  it("302 重定向目标包含 /api/auth/login 路径", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/admin");
    const res = await middleware(req);
    expect(res.status).toBe(302);
    const location = res.headers.get("location");
    expect(location).toBeTruthy();
    expect(location).toContain("/api/auth/login");
  });

  it("无效 cookie（随机字符串）返回 302", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/admin", "garbage.cookie");
    const res = await middleware(req);
    expect(res.status).toBe(302);
  });

  it("过期 session 返回 302", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildExpiredSessionCookie(ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/admin", cookie);
    const res = await middleware(req);
    expect(res.status).toBe(302);
  });
});

describe("middleware — /admin 页面路由：有效管理员 session", () => {
  it("有效管理员 session 放行（不返回 302/401/403）", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildValidSessionCookie(ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/admin", cookie);
    const res = await middleware(req);
    // NextResponse.next() 在 middleware 中通常返回 undefined 或 status 200
    if (res) {
      expect([200, undefined]).toContain(res.status === 200 ? 200 : undefined);
      expect(res.status).not.toBe(302);
      expect(res.status).not.toBe(401);
      expect(res.status).not.toBe(403);
    }
  });

  it("/admin/dashboard 子路由有效 session 也放行", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildValidSessionCookie(ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/admin/dashboard", cookie);
    const res = await middleware(req);
    if (res) {
      expect(res.status).not.toBe(302);
      expect(res.status).not.toBe(401);
      expect(res.status).not.toBe(403);
    }
  });
});

describe("middleware — /admin 页面路由：非管理员 session", () => {
  it("非管理员邮箱的有效 session 返回 403", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildValidSessionCookie(NON_ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/admin", cookie);
    const res = await middleware(req);
    expect(res.status).toBe(403);
  });
});

// ============================================================
// /api/admin/* API 路由
// ============================================================
describe("middleware — /api/admin/* API 路由：无有效 session", () => {
  it("无 cookie 时返回 401 JSON", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/api/admin/skins");
    const res = await middleware(req);
    expect(res.status).toBe(401);
  });

  it("401 响应体为 JSON { error: 'unauthorized' }", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/api/admin/skins");
    const res = await middleware(req);
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body).toHaveProperty("error");
    expect(body.error).toMatch(/unauthorized/i);
  });

  it("无效 cookie 时 /api/admin/* 返回 401", async () => {
    const middleware = await loadMiddleware();
    const req = makeMockRequest("/api/admin/skins", "bad.cookie");
    const res = await middleware(req);
    expect(res.status).toBe(401);
  });

  it("过期 session 时 /api/admin/* 返回 401", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildExpiredSessionCookie(ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/api/admin/skins", cookie);
    const res = await middleware(req);
    expect(res.status).toBe(401);
  });
});

describe("middleware — /api/admin/* API 路由：有效管理员 session", () => {
  it("有效管理员 session 放行（不返回 401/403）", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildValidSessionCookie(ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/api/admin/skins", cookie);
    const res = await middleware(req);
    if (res) {
      expect(res.status).not.toBe(401);
      expect(res.status).not.toBe(403);
    }
  });
});

describe("middleware — /api/admin/* API 路由：非管理员 session", () => {
  it("非管理员邮箱有效 session 返回 403", async () => {
    const middleware = await loadMiddleware();
    const cookie = await buildValidSessionCookie(NON_ADMIN_EMAIL, TEST_SECRET);
    const req = makeMockRequest("/api/admin/skins", cookie);
    const res = await middleware(req);
    expect(res.status).toBe(403);
  });
});
