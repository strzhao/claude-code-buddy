import { deleteSkinRecord, getSkinRecord } from "@/lib/kv";
import { deleteSkinBlobs } from "@/lib/storage";
import { errorResponse } from "@/lib/errors";

export async function DELETE(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { id } = await params;
    const ck = decodeURIComponent(id);

    const record = await getSkinRecord(ck);
    if (!record) {
      return errorResponse(404, "Skin not found");
    }

    await deleteSkinBlobs(record.id, record.version);
    await deleteSkinRecord(ck);

    return new Response(null, { status: 204 });
  } catch {
    return errorResponse(500, "Internal server error");
  }
}
