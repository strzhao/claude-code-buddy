"use client";

import { useState, useCallback } from "react";
import { useTheme } from "./ThemeProvider";

/* ── Palette data ──────────────────────────────────────────── */

interface ColorEntry {
  name: string;
  zh: string;
  hex: string;
  token: string;
}

const CORE_PALETTE: ColorEntry[] = [
  { name: "Ink", zh: "墨", hex: "#1A1A18", token: "--color-ink" },
  { name: "Paper", zh: "纸", hex: "#F7F6F1", token: "--color-canvas" },
  { name: "Mist", zh: "雾", hex: "#EBEBEA", token: "--color-surface-alt" },
  { name: "Smoke", zh: "烟", hex: "#8F8F8D", token: "--color-muted" },
  { name: "Charcoal", zh: "炭", hex: "#595957", token: "--color-secondary" },
  { name: "Sage", zh: "苔", hex: "#3A7D68", token: "--color-primary" },
];

const SUPPORTING_PALETTE: ColorEntry[] = [
  { name: "Sage Light", zh: "苔浅", hex: "#52A688", token: "--color-primary-hover" },
  { name: "Sage Mist", zh: "苔淡", hex: "#E8F2EE", token: "--color-primary-mist" },
  { name: "Amber", zh: "琥", hex: "#D4920A", token: "--color-warning" },
  { name: "Vermillion", zh: "朱", hex: "#D94F3D", token: "--color-error" },
  { name: "Sky", zh: "天", hex: "#3B87CC", token: "--color-info" },
];

/* ── Components ────────────────────────────────────────────── */

function ColorSwatch({ entry }: { entry: ColorEntry }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(entry.hex);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard API not available (non-HTTPS)
    }
  }, [entry.hex]);

  const isLight = entry.hex === "#F7F6F1" || entry.hex === "#EBEBEA" || entry.hex === "#E8F2EE";

  return (
    <button
      onClick={handleCopy}
      className="group flex flex-col items-center gap-2 focus:outline-none"
    >
      <div
        className={`h-16 w-16 rounded pixel-border transition-transform group-hover:scale-105 group-active:scale-100 ${
          isLight ? "border-border-pixel" : ""
        }`}
        style={{ backgroundColor: entry.hex }}
      />
      <div className="text-center">
        <p className="text-xs font-medium text-ink">
          {entry.zh} <span className="text-muted">{entry.name}</span>
        </p>
        <p className="font-mono text-[10px] text-muted">{copied ? "Copied!" : entry.hex}</p>
      </div>
    </button>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return <h2 className="pixel-heading text-lg text-ink mb-4 mt-10 first:mt-0">{children}</h2>;
}

function ComponentShowcase() {
  const [activeTab, setActiveTab] = useState(0);
  const tabs = ["Pending", "Approved", "Rejected"];

  return (
    <div className="space-y-6">
      {/* Buttons */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Buttons</h3>
        <div className="flex flex-wrap gap-3">
          <button className="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-text pixel-shadow-sm pixel-btn-active transition-colors hover:bg-primary-hover">
            Primary
          </button>
          <button className="rounded border border-border-strong bg-surface px-4 py-2 text-sm font-medium text-secondary pixel-shadow-sm pixel-btn-active transition-colors hover:text-ink">
            Secondary
          </button>
          <button className="rounded bg-error px-4 py-2 text-sm font-medium text-primary-text pixel-shadow-sm pixel-btn-active transition-colors hover:brightness-90">
            Danger
          </button>
          <button
            disabled
            className="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-text opacity-50 cursor-not-allowed"
          >
            Disabled
          </button>
        </div>
      </div>

      {/* Badges */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Status Badges</h3>
        <div className="flex flex-wrap gap-3">
          <span className="inline-flex items-center rounded border-2 border-warning bg-warning-light px-2 py-0.5 font-mono text-[10px] font-medium uppercase tracking-wider text-warning-text">
            pending
          </span>
          <span className="inline-flex items-center rounded border-2 border-success bg-success-light px-2 py-0.5 font-mono text-[10px] font-medium uppercase tracking-wider text-success-text">
            approved
          </span>
          <span className="inline-flex items-center rounded border-2 border-error bg-error-light px-2 py-0.5 font-mono text-[10px] font-medium uppercase tracking-wider text-error-text">
            rejected
          </span>
        </div>
      </div>

      {/* Tabs */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Tab Bar</h3>
        <div className="flex gap-0 rounded bg-surface pixel-border overflow-hidden w-fit">
          {tabs.map((tab, i) => (
            <button
              key={tab}
              onClick={() => setActiveTab(i)}
              className={`px-5 py-2.5 text-sm font-medium transition-colors ${
                activeTab === i
                  ? "bg-primary text-primary-text"
                  : "text-secondary hover:bg-surface-alt hover:text-ink"
              }`}
            >
              {tab}
            </button>
          ))}
        </div>
      </div>

      {/* Card */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Card</h3>
        <div className="max-w-sm rounded bg-surface p-4 pixel-border pixel-shadow-sm">
          <p className="font-semibold text-ink">Pixel Cat Default</p>
          <p className="text-sm text-muted mt-1">
            The original pixel cat sprite pack with 8 animation states.
          </p>
          <div className="mt-3 flex gap-2">
            <span className="inline-flex items-center rounded border-2 border-success bg-success-light px-2 py-0.5 font-mono text-[10px] font-medium uppercase tracking-wider text-success-text">
              approved
            </span>
            <span className="text-xs text-muted">v1.0.0</span>
          </div>
        </div>
      </div>

      {/* Inputs */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Inputs</h3>
        <div className="max-w-sm space-y-3">
          <input
            type="text"
            placeholder="Your name or handle"
            readOnly
            className="block w-full rounded-md border border-border-strong bg-surface px-3 py-2 text-sm text-secondary placeholder-placeholder focus:border-focus focus:outline-none focus:ring-1 focus:ring-focus"
          />
          <input
            type="file"
            disabled
            className="block w-full rounded-md border border-border-strong px-3 py-2 text-sm text-secondary file:mr-3 file:cursor-pointer file:rounded file:border-0 file:bg-surface-alt file:px-3 file:py-1 file:text-sm file:font-medium file:text-secondary"
          />
        </div>
      </div>

      {/* Alerts */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Alerts</h3>
        <div className="space-y-3 max-w-sm">
          <div className="rounded border border-success bg-success-light p-3 text-sm text-success-text">
            Upload successful!
          </div>
          <div className="rounded border border-error bg-error-light p-3 text-sm text-error-text">
            File exceeds 5 MB limit.
          </div>
          <div className="rounded border border-warning bg-warning-light p-3 text-sm text-warning-text">
            Pending review.
          </div>
          <div className="rounded border border-info bg-info-light p-3 text-sm text-info-text">
            API endpoint updated.
          </div>
        </div>
      </div>
    </div>
  );
}

function PixelArtDemo() {
  return (
    <div className="space-y-6">
      {/* Shadows */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Pixel Shadows</h3>
        <div className="flex flex-wrap gap-6">
          {(
            [
              ["pixel-shadow-sm", "SM"],
              ["pixel-shadow", "MD"],
              ["pixel-shadow-lg", "LG"],
              ["pixel-shadow-layered", "Layered"],
              ["pixel-shadow-primary", "Primary"],
            ] as const
          ).map(([cls, label]) => (
            <div key={cls} className="flex flex-col items-center gap-2">
              <div className={`h-16 w-16 rounded bg-surface pixel-border ${cls}`} />
              <span className="font-mono text-[10px] text-muted">{label}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Borders */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Pixel Borders</h3>
        <div className="flex flex-wrap gap-6">
          <div className="flex flex-col items-center gap-2">
            <div className="h-16 w-16 rounded bg-surface pixel-border" />
            <span className="font-mono text-[10px] text-muted">Default</span>
          </div>
          <div className="flex flex-col items-center gap-2">
            <div className="h-16 w-16 rounded bg-surface pixel-border-thick" />
            <span className="font-mono text-[10px] text-muted">Thick</span>
          </div>
          <div className="flex flex-col items-center gap-2">
            <div className="h-16 w-16 rounded bg-surface pixel-border-primary" />
            <span className="font-mono text-[10px] text-muted">Primary</span>
          </div>
        </div>
      </div>

      {/* Corner decorations */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Pixel Corners</h3>
        <div className="inline-block rounded bg-surface p-6 pixel-border pixel-corners">
          <p className="text-sm text-ink">L-bracket corner decorations</p>
        </div>
      </div>

      {/* Pixel rendering */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Pixel Rendering</h3>
        <div className="flex items-center gap-4">
          {/* 4x4 checkerboard scaled up to demonstrate pixel-render */}
          <div className="relative h-16 w-16 overflow-hidden rounded pixel-border bg-primary">
            <div
              className="absolute inset-0 pixel-render"
              style={{
                backgroundImage: `
                linear-gradient(45deg, var(--color-primary-hover) 25%, transparent 25%),
                linear-gradient(-45deg, var(--color-primary-hover) 25%, transparent 25%),
                linear-gradient(45deg, transparent 75%, var(--color-primary-hover) 75%),
                linear-gradient(-45deg, transparent 75%, var(--color-primary-hover) 75%)
              `,
                backgroundSize: "16px 16px",
                backgroundPosition: "0 0, 0 8px, 8px -8px, -8px 0",
              }}
            />
          </div>
          <p className="text-sm text-muted">
            <code className="rounded bg-surface-alt px-1 py-0.5 text-xs font-mono">
              .pixel-render
            </code>{" "}
            — crisp edges for sprites
          </p>
        </div>
      </div>

      {/* Typography */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Pixel Heading</h3>
        <p className="pixel-heading text-2xl text-ink">Claude Code Buddy</p>
        <p className="text-sm text-muted mt-1">
          <code className="rounded bg-surface-alt px-1 py-0.5 text-xs font-mono">
            .pixel-heading
          </code>{" "}
          — Geist Mono, bold, tracked
        </p>
      </div>

      {/* Press effect */}
      <div>
        <h3 className="text-sm font-medium text-secondary mb-3">Press Effect</h3>
        <button className="rounded bg-primary px-6 py-3 text-sm font-medium text-primary-text pixel-shadow pixel-btn-active transition-colors hover:bg-primary-hover">
          Click me!
        </button>
        <p className="text-sm text-muted mt-2">
          <code className="rounded bg-surface-alt px-1 py-0.5 text-xs font-mono">
            .pixel-btn-active
          </code>{" "}
          — 2px translate + shadow removal on :active
        </p>
      </div>
    </div>
  );
}

/* ── Main showcase ─────────────────────────────────────────── */

export default function ColorsShowcase() {
  const { theme, toggleTheme } = useTheme();

  return (
    <main className="min-h-screen bg-canvas p-6 md:p-12">
      <div className="mx-auto max-w-4xl">
        {/* Header */}
        <div className="mb-10 flex items-center justify-between">
          <div>
            <h1 className="pixel-heading text-3xl text-ink">Color System</h1>
            <p className="text-sm text-muted mt-1">
              Pixel-art design tokens for Claude Code Buddy Skin Store
            </p>
          </div>
          <button
            onClick={toggleTheme}
            className="rounded bg-surface px-4 py-2 text-sm font-medium text-secondary pixel-border pixel-shadow-sm pixel-btn-active transition-colors hover:text-ink"
          >
            {theme === "light" ? "☾ Dark" : "☀ Light"}
          </button>
        </div>

        {/* Core Palette */}
        <SectionTitle>Core Palette</SectionTitle>
        <div className="grid grid-cols-3 sm:grid-cols-6 gap-4">
          {CORE_PALETTE.map((c) => (
            <ColorSwatch key={c.name} entry={c} />
          ))}
        </div>

        {/* Supporting Palette */}
        <SectionTitle>Supporting Palette</SectionTitle>
        <div className="grid grid-cols-3 sm:grid-cols-5 gap-4">
          {SUPPORTING_PALETTE.map((c) => (
            <ColorSwatch key={c.name} entry={c} />
          ))}
        </div>

        {/* Semantic Tokens */}
        <SectionTitle>Semantic Tokens</SectionTitle>
        <div className="rounded bg-surface p-4 pixel-border overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left">
                <th className="pb-2 pr-4 font-medium text-ink">Token</th>
                <th className="pb-2 pr-4 font-medium text-ink">Preview</th>
                <th className="pb-2 font-medium text-ink">Usage</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {[
                { token: "canvas", usage: "Page background", bg: true },
                { token: "surface", usage: "Cards, containers", bg: true },
                { token: "surface-alt", usage: "Code blocks, alt rows", bg: true },
                { token: "ink", usage: "Primary text", text: true },
                { token: "secondary", usage: "Labels, metadata", text: true },
                { token: "muted", usage: "Descriptions, hints", text: true },
                { token: "primary", usage: "Brand buttons, CTAs", bg: true },
                { token: "primary-hover", usage: "Hover state", bg: true },
                { token: "primary-mist", usage: "Brand bg fill", bg: true },
                { token: "success", usage: "Success state", bg: true },
                { token: "warning", usage: "Warning state", bg: true },
                { token: "error", usage: "Error / danger", bg: true },
                { token: "info", usage: "Info / links", bg: true },
              ].map((row) => (
                <tr key={row.token}>
                  <td className="py-2 pr-4 font-mono text-xs text-muted">--color-{row.token}</td>
                  <td className="py-2 pr-4">
                    {row.bg ? (
                      <div className={`h-6 w-12 rounded border border-border bg-${row.token}`} />
                    ) : (
                      <span className={`font-medium text-${row.token}`}>Aa</span>
                    )}
                  </td>
                  <td className="py-2 text-xs text-secondary">{row.usage}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Component Showcase */}
        <SectionTitle>Components</SectionTitle>
        <ComponentShowcase />

        {/* Pixel Art Elements */}
        <SectionTitle>Pixel Art Elements</SectionTitle>
        <PixelArtDemo />

        {/* Footer */}
        <hr className="pixel-divider mt-12 mb-6" />
        <p className="text-center text-xs text-muted">
          Based on{" "}
          <a
            href="https://stringzhao.life/colors"
            target="_blank"
            rel="noopener noreferrer"
            className="text-primary hover:text-primary-hover underline"
          >
            stringzhao.life/colors
          </a>{" "}
          — adapted for pixel art aesthetic
        </p>
      </div>
    </main>
  );
}
