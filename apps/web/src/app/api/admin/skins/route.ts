import type { NextRequest } from "next/server";

import { errorResponse } from "@/lib/errors";
import { listSkinsByStatus } from "@/lib/kv";
import type { SkinStatus } from "@/lib/types";

export async function GET(request: NextRequest) {
  try {
    const searchParams = request.nextUrl.searchParams;
    const statusParam = searchParams.get("status") ?? "pending";

    const validStatuses = ["pending", "approved", "rejected", "all"];
    if (!validStatuses.includes(statusParam)) {
      return errorResponse(400, "Invalid status parameter");
    }

    const records = await listSkinsByStatus(statusParam as SkinStatus | "all");

    return Response.json(records);
  } catch {
    return errorResponse(500, "Internal server error");
  }
}
