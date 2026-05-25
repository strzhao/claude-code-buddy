"use client";

import { useRef, useEffect, useState } from "react";
import { SceneEngine } from "./engine/SceneEngine";

export default function PixiScene() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<SceneEngine | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;

    let destroyed = false;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && !engineRef.current && !destroyed) {
          const engine = new SceneEngine();
          engineRef.current = engine;
          const width = container.clientWidth;
          const height = container.clientHeight;
          canvas.width = width;
          canvas.height = height;
          engine.init(canvas, width, height).then(() => {
            if (!destroyed) setReady(true);
          });
        }
      },
      { threshold: 0.1 },
    );
    observer.observe(container);

    const resizeObserver = new ResizeObserver(([entry]) => {
      if (!engineRef.current) return;
      const { width, height } = entry.contentRect;
      engineRef.current.resize(width, height);
    });
    resizeObserver.observe(container);

    return () => {
      destroyed = true;
      observer.disconnect();
      resizeObserver.disconnect();
      if (engineRef.current) {
        engineRef.current.destroy();
        engineRef.current = null;
      }
    };
  }, []);

  return (
    <div ref={containerRef} className="w-full h-full relative">
      <canvas
        ref={canvasRef}
        className="w-full h-full pixel-render"
        style={{ imageRendering: "pixelated" }}
      />
      {!ready && (
        <div className="absolute inset-0 flex items-center justify-center">
          <p className="pixel-heading text-muted text-sm animate-pixel-shimmer">猫咪正在赶来...</p>
        </div>
      )}
    </div>
  );
}
