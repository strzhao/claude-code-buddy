import { NextResponse } from "next/server";

import { getSkinRecord, moveSkinStatus } from "@/lib/kv";
import { errorResponse } from "@/lib/errors";

export async function POST(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { id } = await params;
    const ck = decodeURIComponent(id);

    const record = await getSkinRecord(ck);
    if (!record) {
      return errorResponse(404, "Skin not found");
    }

    if (record.status !== "pending") {
      return errorResponse(
        400,
        "Invalid status transition",
        `Skin is already "${record.status}", can only approve pending skins`,
      );
    }

    const updated = await moveSkinStatus(ck, "pending", "approved", {
      updated_at: new Date().toISOString(),
    });

    return NextResponse.json(updated);
  } catch {
    return errorResponse(500, "Internal server error");
  }
}
