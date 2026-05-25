"use client";

import { useState } from "react";
import type { SkinRecord } from "@/lib/types";

export default function SkinCard({ skin }: { skin: SkinRecord }) {
  const [hovered, setHovered] = useState(false);

  return (
    <div
      className={`bg-surface rounded pixel-border p-4 flex flex-col transition-transform ${
        hovered ? "pixel-shadow -translate-y-0.5" : "pixel-shadow-sm"
      }`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      {skin.preview_blob_url ? (
        <div className="w-full aspect-square bg-surface-alt rounded mb-3 flex items-center justify-center overflow-hidden">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={skin.preview_blob_url}
            alt={skin.name}
            className="pixel-render w-full h-full object-contain"
            loading="lazy"
            decoding="async"
          />
        </div>
      ) : (
        <div className="w-full aspect-square bg-surface-alt rounded mb-3 flex items-center justify-center">
          <span className="text-3xl">🐱</span>
        </div>
      )}
      <h3 className="pixel-heading text-sm text-ink truncate">{skin.name}</h3>
      <p className="text-muted text-xs mt-1">{skin.author}</p>
    </div>
  );
}
