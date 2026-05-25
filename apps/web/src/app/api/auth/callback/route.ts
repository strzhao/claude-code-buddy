import { type NextRequest, NextResponse } from "next/server";
import { createRemoteJwksVerifier } from "@stringzhao/auth-sdk";
import {
  AUTH_STATE_COOKIE_NAME,
  GATEWAY_COOKIE_NAME,
  GATEWAY_SESSION_TTL_SECONDS,
  createGatewaySession,
  isAdminEmail,
} from "@/lib/auth";

const JWKS_URL = "https://user.stringzhao.life/.well-known/jwks.json";
const ISSUER = "https://user.stringzhao.life";
const AUDIENCE = "base-account-client";

/** Clear the auth_state cookie in a response */
function clearStateCookie(response: NextResponse): void {
  response.cookies.set(AUTH_STATE_COOKIE_NAME, "", {
    httpOnly: true,
    path: "/",
    maxAge: 0,
  });
}

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const returnedState = searchParams.get("state");

  // ── CSRF: validate state ────────────────────────────────────────────────────
  const rawStateCookie = request.cookies.get(AUTH_STATE_COOKIE_NAME)?.value;
  let savedState: string | null = null;
  let returnTo = "/admin";

  if (rawStateCookie) {
    try {
      const parsed = JSON.parse(rawStateCookie) as {
        state: string;
        returnTo?: string;
      };
      savedState = parsed.state;
      returnTo = parsed.returnTo ?? "/admin";
    } catch {
      // malformed cookie — treat as no state
    }
  }

  if (!returnedState || returnedState !== savedState) {
    const response = new NextResponse("Invalid or missing state parameter", {
      status: 400,
    });
    clearStateCookie(response);
    return response;
  }

  // ── Read access_token cookie (set by account center on shared domain) ───────
  const accessToken = request.cookies.get("access_token")?.value;
  if (!accessToken) {
    const response = new NextResponse("access_token cookie not found", {
      status: 400,
    });
    clearStateCookie(response);
    return response;
  }

  // ── Verify JWT ───────────────────────────────────────────────────────────────
  let email: string;
  try {
    const verifier = createRemoteJwksVerifier({
      jwksUrl: JWKS_URL,
      config: { issuer: ISSUER, audience: AUDIENCE },
    });
    const payload = await verifier.verifyAccessToken(accessToken);
    email = payload.email;
  } catch (err) {
    console.error("[auth/callback] JWT verification failed:", err);
    const response = new NextResponse(
      `<!doctype html><html><body>
        <h1>认证服务暂时不可用</h1>
        <p>无法验证您的身份，请稍后重试。</p>
        <a href="/">返回首页</a>
      </body></html>`,
      {
        status: 503,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      },
    );
    clearStateCookie(response);
    return response;
  }

  // ── Admin permission check ───────────────────────────────────────────────────
  if (!isAdminEmail(email)) {
    const safeEmail = email.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const response = new NextResponse(
      `<!doctype html><html><body>
        <h1>无访问权限</h1>
        <p>您的账号（${safeEmail}）没有管理员权限。</p>
        <a href="/">返回首页</a>
      </body></html>`,
      {
        status: 403,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      },
    );
    clearStateCookie(response);
    return response;
  }

  // ── Create gateway session cookie ────────────────────────────────────────────
  let sessionValue: string;
  try {
    sessionValue = await createGatewaySession(email);
  } catch (err) {
    console.error("[auth/callback] Failed to create gateway session:", err);
    const response = new NextResponse("Internal server error", { status: 500 });
    clearStateCookie(response);
    return response;
  }

  const response = NextResponse.redirect(new URL(returnTo, request.nextUrl.origin).toString(), {
    status: 302,
  });

  response.cookies.set(GATEWAY_COOKIE_NAME, sessionValue, {
    httpOnly: true,
    sameSite: "lax",
    path: "/",
    maxAge: GATEWAY_SESSION_TTL_SECONDS,
    secure: process.env.NODE_ENV === "production",
  });

  clearStateCookie(response);
  return response;
}
