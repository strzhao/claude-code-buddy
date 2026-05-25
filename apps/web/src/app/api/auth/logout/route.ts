import { type NextRequest, NextResponse } from "next/server";
import { GATEWAY_COOKIE_NAME } from "@/lib/auth";

function buildLogoutResponse(request: NextRequest): NextResponse {
  const origin = process.env.APP_BASE_URL ?? request.nextUrl.origin;
  const response = NextResponse.redirect(new URL("/", origin).toString(), {
    status: 302,
  });

  // Clear the gateway session cookie
  response.cookies.set(GATEWAY_COOKIE_NAME, "", {
    httpOnly: true,
    path: "/",
    maxAge: 0,
  });

  return response;
}

export function GET(request: NextRequest) {
  return buildLogoutResponse(request);
}

export function POST(request: NextRequest) {
  return buildLogoutResponse(request);
}
