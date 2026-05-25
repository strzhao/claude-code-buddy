"use client";

import { useEffect, useRef, useState } from "react";
import { FRAME_COUNTS, PHYSICS } from "./engine/types";

const TOTAL_FRAMES = FRAME_COUNTS["idle-a"]; // 8
const INTERVAL_MS = Math.round(1000 / PHYSICS.animFps); // 125ms

function frameUrl(frame: number): string {
  return `/sprites/cats/cat-idle-a-${frame}.png`;
}

export default function CatSkinCard() {
  const [hovered, setHovered] = useState(false);
  const [frame, setFrame] = useState(1);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Preload all frames on mount
  useEffect(() => {
    for (let i = 1; i <= TOTAL_FRAMES; i++) {
      const img = new window.Image();
      img.src = frameUrl(i);
    }
  }, []);

  // Start/stop animation based on hover state
  useEffect(() => {
    if (hovered) {
      intervalRef.current = setInterval(() => {
        setFrame((prev) => (prev % TOTAL_FRAMES) + 1);
      }, INTERVAL_MS);
    } else {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
      const reset = async () => {
        setFrame(1);
      };
      reset();
    }

    return () => {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
    };
  }, [hovered]);

  return (
    <div
      className={`bg-surface rounded pixel-border p-4 flex flex-col cursor-default transition-transform ${
        hovered ? "pixel-shadow -translate-y-0.5" : "pixel-shadow-sm"
      }`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      <div className="w-full aspect-square bg-surface-alt rounded mb-3 flex items-center justify-center overflow-hidden">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={frameUrl(frame)}
          alt="默认猫咪皮肤"
          className="pixel-render w-full h-full object-contain"
          draggable={false}
        />
      </div>
      <h3 className="pixel-heading text-sm text-ink truncate">默认猫咪</h3>
      <p className="text-muted text-xs mt-1">内置皮肤</p>
    </div>
  );
}
