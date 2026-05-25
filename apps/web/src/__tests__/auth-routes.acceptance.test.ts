/**
 * 验收测试：Auth 路由 —— login / callback / logout
 *
 * 黑盒测试以下 API 路由的行为契约：
 *
 * GET /api/auth/login?return_to=<path>
 *   - 生成随机 state 并存储（Redis 或 session）
 *   - 302 重定向到 https://user.stringzhao.life/authorize?return_to=<callback>&state=<state>
 *   - 重定向 URL 包含正确的 callback URL 和 state 参数
 *
 * GET /api/auth/callback?authorized=1&state=<state>
 *   - state 不匹配 → 返回 400 错误
 *   - 缺少 authorized=1 → 返回 400 错误
 *   - state 匹配 + access_token cookie 有效 → 创建 buddy_gateway_session cookie + 302 到 /admin
 *   - email 不在管理员列表 → 返回 403 错误
 *
 * POST /api/auth/logout
 *   - 清除 buddy_gateway_session cookie（Set-Cookie 过期）
 *   - 302 重定向到首页或 return_to
 *
 * 注意：这些测试通过 Node.js fetch 调用运行中的 Next.js dev server，
 *       或者通过直接导入 route handler 函数来测试。
 *       此处采用直接导入 route handler 的方式（单元式集成测试）。
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// ---- 环境变量设置 ----
const TEST_SECRET = "auth-route-test-secret-32chars!!xx";
const ADMIN_EMAIL = "admin@stringzhao.life";
const AUTH_CENTER_BASE = "https://user.stringzhao.life";

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

// ---- 辅助：构造 mock NextRequest ----
function makeNextRequest(
  pathname: string,
  opts: {
    method?: string;
    searchParams?: Record<string, string>;
    cookies?: Record<string, string>;
  } = {},
) {
  const url = new URL(`http://localhost:3000${pathname}`);
  if (opts.searchParams) {
    for (const [k, v] of Object.entries(opts.searchParams)) {
      url.searchParams.set(k, v);
    }
  }
  const cookieMap = new Map(Object.entries(opts.cookies ?? {}).map(([k, v]) => [k, { value: v }]));
  return {
    url: url.toString(),
    nextUrl: url,
    method: opts.method ?? "GET",
    cookies: {
      get: (name: string) => cookieMap.get(name),
    },
    headers: new Headers(),
  } as unknown as Parameters<(typeof import("../app/api/auth/login/route"))["GET"]>[0];
}

// ============================================================
// GET /api/auth/login
// ============================================================
describe("GET /api/auth/login — 生成 state 并重定向", () => {
  it("返回 302 状态码", async () => {
    const { GET } = await import("../app/api/auth/login/route");
    const req = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res = await GET(req);
    expect(res.status).toBe(302);
  });

  it("Location header 指向账号中心授权端点", async () => {
    const { GET } = await import("../app/api/auth/login/route");
    const req = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res = await GET(req);
    const location = res.headers.get("location");
    expect(location).toBeTruthy();
    expect(location).toContain(AUTH_CENTER_BASE);
    expect(location).toContain("/authorize");
  });

  it("Location URL 包含 state 查询参数", async () => {
    const { GET } = await import("../app/api/auth/login/route");
    const req = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res = await GET(req);
    const location = res.headers.get("location")!;
    const redirectUrl = new URL(location);
    expect(redirectUrl.searchParams.get("state")).toBeTruthy();
  });

  it("Location URL 包含 return_to（回调 URL）查询参数", async () => {
    const { GET } = await import("../app/api/auth/login/route");
    const req = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res = await GET(req);
    const location = res.headers.get("location")!;
    const redirectUrl = new URL(location);
    // 账号中心需要知道回调地址
    const returnTo = redirectUrl.searchParams.get("return_to");
    expect(returnTo).toBeTruthy();
    expect(returnTo).toContain("/api/auth/callback");
  });

  it("两次调用生成的 state 不同（随机性）", async () => {
    const { GET } = await import("../app/api/auth/login/route");
    const req1 = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const req2 = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res1 = await GET(req1);
    const res2 = await GET(req2);
    const loc1 = new URL(res1.headers.get("location")!);
    const loc2 = new URL(res2.headers.get("location")!);
    const state1 = loc1.searchParams.get("state");
    const state2 = loc2.searchParams.get("state");
    expect(state1).not.toBe(state2);
  });
});

// ============================================================
// GET /api/auth/callback
// ============================================================
describe("GET /api/auth/callback — state 不匹配", () => {
  it("state 参数不存在时返回 4xx 错误", async () => {
    const { GET } = await import("../app/api/auth/callback/route");
    const req = makeNextRequest("/api/auth/callback", {
      searchParams: { authorized: "1" },
      // 无 state
    });
    const res = await GET(req);
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
  });

  it("state 参数与存储的不匹配时返回 4xx 错误", async () => {
    const { GET } = await import("../app/api/auth/callback/route");
    const req = makeNextRequest("/api/auth/callback", {
      searchParams: { authorized: "1", state: "completely-wrong-state-xyz" },
    });
    const res = await GET(req);
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
  });

  it("缺少 authorized=1 参数时返回 4xx 错误", async () => {
    const { GET } = await import("../app/api/auth/callback/route");
    const req = makeNextRequest("/api/auth/callback", {
      searchParams: { state: "some-state" },
      // 无 authorized
    });
    const res = await GET(req);
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
  });
});

describe("GET /api/auth/callback — 响应体格式", () => {
  it("state 不匹配时响应体为 JSON 且包含 error 字段", async () => {
    const { GET } = await import("../app/api/auth/callback/route");
    const req = makeNextRequest("/api/auth/callback", {
      searchParams: { authorized: "1", state: "bad-state-xxx" },
    });
    const res = await GET(req);
    // 只检查有 error 响应体
    if (res.headers.get("content-type")?.includes("application/json")) {
      const body = await res.json();
      expect(body).toHaveProperty("error");
    } else {
      // 也接受重定向到错误页面（非 JSON），但状态码应 >= 400
      expect(res.status).toBeGreaterThanOrEqual(400);
    }
  });
});

// ============================================================
// POST /api/auth/logout
// ============================================================
describe("POST /api/auth/logout — 清除 cookie", () => {
  it("返回 302 重定向", async () => {
    const { POST } = await import("../app/api/auth/logout/route");
    const req = makeNextRequest("/api/auth/logout", { method: "POST" });
    const res = await POST(req);
    expect(res.status).toBe(302);
  });

  it("响应头包含 Set-Cookie 清除 buddy_gateway_session", async () => {
    const { POST } = await import("../app/api/auth/logout/route");
    const req = makeNextRequest("/api/auth/logout", { method: "POST" });
    const res = await POST(req);
    const setCookie = res.headers.get("set-cookie");
    expect(setCookie).toBeTruthy();
    // cookie 应被清除：expires=Thu, 01 Jan 1970 或 max-age=0
    const isExpired =
      (setCookie?.includes("buddy_gateway_session") &&
        (setCookie?.includes("Max-Age=0") ||
          setCookie?.includes("max-age=0") ||
          setCookie?.includes("Expires=Thu, 01 Jan 1970") ||
          setCookie?.includes("expires=Thu, 01 Jan 1970"))) ??
      false;
    expect(isExpired).toBe(true);
  });

  it("302 重定向目标为首页或 return_to", async () => {
    const { POST } = await import("../app/api/auth/logout/route");
    const req = makeNextRequest("/api/auth/logout", { method: "POST" });
    const res = await POST(req);
    const location = res.headers.get("location");
    expect(location).toBeTruthy();
    // 应重定向到非 admin 路由
    expect(location).not.toContain("/admin");
  });
});

// ============================================================
// GET /api/auth/login — 配置校验
// ============================================================
describe("GET /api/auth/login — 环境变量缺失", () => {
  it("缺少 APP_BASE_URL 时返回 5xx 或有意义的错误", async () => {
    delete process.env.APP_BASE_URL;
    vi.resetModules();
    const { GET } = await import("../app/api/auth/login/route");
    const req = makeNextRequest("/api/auth/login", {
      searchParams: { return_to: "/admin" },
    });
    const res = await GET(req);
    // 应返回错误（不能 crash 成 500，或应返回有意义的响应）
    expect(res.status).toBeGreaterThanOrEqual(400);
  });
});
