import { NextResponse } from "next/server";
import type { ApiError } from "./types";

export function errorResponse(status: number, error: string, details?: string) {
  return NextResponse.json({ error, details } satisfies ApiError, { status });
}
