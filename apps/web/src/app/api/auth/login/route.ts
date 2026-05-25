import { type NextRequest, NextResponse } from "next/server";
import { AUTH_STATE_COOKIE_NAME } from "@/lib/auth";

const ACCOUNT_CENTER_URL = "https://user.stringzhao.life";

export function GET(request: NextRequest) {
  const appBaseUrl = process.env.APP_BASE_URL;
  if (!appBaseUrl) {
    return new NextResponse("APP_BASE_URL is not configured", { status: 500 });
  }

  // Determine the return_to destination after successful auth
  const rawReturnTo = request.nextUrl.searchParams.get("return_to") ?? "/admin";
  const returnTo =
    rawReturnTo.startsWith("/") && !rawReturnTo.startsWith("//") ? rawReturnTo : "/admin";

  // Generate a random state value for CSRF protection
  const state = crypto.randomUUID();

  // Construct the callback URL (absolute)
  const callbackUrl = `${appBaseUrl}/api/auth/callback`;

  // Build the authorize URL at the account center
  const authorizeUrl = new URL(`${ACCOUNT_CENTER_URL}/authorize`);
  authorizeUrl.searchParams.set("return_to", callbackUrl);
  authorizeUrl.searchParams.set("state", state);

  // Store state + intended destination in a short-lived cookie
  const response = NextResponse.redirect(authorizeUrl.toString(), {
    status: 302,
  });

  // Pack state and return_to together so callback knows where to send the user
  const statePayload = JSON.stringify({ state, returnTo });
  response.cookies.set(AUTH_STATE_COOKIE_NAME, statePayload, {
    httpOnly: true,
    sameSite: "lax",
    path: "/",
    maxAge: 300, // 5 minutes
    secure: process.env.NODE_ENV === "production",
  });

  return response;
}
