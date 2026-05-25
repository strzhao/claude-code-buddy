"use client";

import dynamic from "next/dynamic";

const PixiScene = dynamic(() => import("./PixiScene"), {
  ssr: false,
  loading: () => (
    <div className="w-full h-full bg-surface-alt flex items-center justify-center">
      <p className="pixel-heading text-muted text-sm">猫咪正在赶来...</p>
    </div>
  ),
});

export default function HeroSection() {
  return (
    <section className="relative w-full h-[300px] sm:h-[400px] overflow-hidden bg-surface-alt">
      <div className="absolute inset-0">
        <PixiScene />
      </div>
      <div className="relative z-10 flex flex-col items-start justify-end h-full px-6 sm:px-12 pb-8 pointer-events-none">
        <p className="font-mono text-primary text-xs sm:text-sm mb-1 tracking-wider uppercase">
          像素猫咪
        </p>
        <h1 className="pixel-heading text-3xl sm:text-4xl lg:text-5xl text-ink mb-3 leading-tight">
          让 Claude Code 会话
          <br />
          更有温度
        </h1>
        <p className="text-secondary text-sm sm:text-base mb-5 max-w-md">
          macOS 桌面伴侣 — 需要授权时猫咪提醒你，任务完成时通知你，菜单栏实时监控 Token 开销
        </p>
        <div className="flex items-center gap-4 pointer-events-auto">
          <a
            href="#install"
            className="rounded bg-primary text-primary-text px-5 py-2.5 font-mono text-sm pixel-shadow-sm pixel-btn-active hover:bg-primary-hover transition-colors"
          >
            免费下载
          </a>
          <a
            href="#skins"
            className="text-primary hover:text-primary-hover font-mono text-sm transition-colors"
          >
            浏览皮肤商店 →
          </a>
        </div>
        <p className="text-muted text-xs mt-4">👆 点击画面投喂猫咪</p>
      </div>
    </section>
  );
}
