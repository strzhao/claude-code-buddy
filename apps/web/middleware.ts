import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { verifyGatewaySession, isAdminEmail, GATEWAY_COOKIE_NAME } from "@/lib/auth";

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Get and verify the gateway session cookie
  const sessionCookie = request.cookies.get(GATEWAY_COOKIE_NAME)?.value;
  const isApiRoute = pathname.startsWith("/api/");

  if (sessionCookie) {
    const payload = await verifyGatewaySession(sessionCookie);
    if (payload) {
      // Valid session — check admin permission
      if (isAdminEmail(payload.email)) {
        return NextResponse.next();
      }
      // Authenticated but not admin → 403
      if (isApiRoute) {
        return NextResponse.json({ error: "forbidden" }, { status: 403 });
      }
      return new NextResponse(null, { status: 403 });
    }
  }

  // No session or invalid/expired session
  if (isApiRoute) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  // Page routes redirect to login
  const loginUrl = new URL("/api/auth/login", request.nextUrl.origin);
  loginUrl.searchParams.set("return_to", pathname);
  return NextResponse.redirect(loginUrl.toString(), { status: 302 });
}

export const config = {
  matcher: ["/admin/:path*", "/api/admin/:path*"],
};
