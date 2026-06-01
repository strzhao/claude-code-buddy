import Link from "next/link";
import SkinCard from "./SkinCard";
import CatSkinCard from "./CatSkinCard";
import { REDIS_READ_TIMEOUT_MS } from "@/lib/constants";
import { withTimeout } from "@/lib/timeout";
import type { SkinRecord } from "@/lib/types";

// Homepage is non-critical to the skins list: if Redis is slow/unreachable
// (e.g. an outage, or no creds in CI), the @upstash/redis client retries with
// exponential backoff for several seconds. Bound the wait so the page always
// renders fast, degrading to an empty list rather than hanging on the request.
async function getApprovedSkins(): Promise<SkinRecord[]> {
  try {
    const { listSkinsByStatus } = await import("@/lib/kv");
    return await withTimeout(listSkinsByStatus("approved"), REDIS_READ_TIMEOUT_MS);
  } catch {
    return [];
  }
}

export default async function SkinsSection() {
  const skins = await getApprovedSkins();

  return (
    <section id="skins" className="py-16 px-6">
      <div className="max-w-4xl mx-auto">
        <h2 className="pixel-heading text-3xl text-ink mb-10 text-center">皮肤商店</h2>
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
          <CatSkinCard />
          {skins.map((skin) => (
            <SkinCard key={`${skin.id}:${skin.version}`} skin={skin} />
          ))}
          <Link
            href="/upload"
            className="bg-surface-alt rounded pixel-border border-dashed border-border-strong p-4 flex flex-col items-center justify-center text-center hover:border-primary transition-colors min-h-[160px]"
          >
            <span className="text-2xl mb-2">+</span>
            <span className="text-secondary text-sm">上传你的皮肤包 →</span>
          </Link>
        </div>
      </div>
    </section>
  );
}
