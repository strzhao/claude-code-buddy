"use client";

import { useTheme } from "./ThemeProvider";

export function ThemeToggle() {
  const { theme, toggleTheme } = useTheme();

  return (
    <button
      onClick={toggleTheme}
      className="rounded bg-surface pixel-border pixel-shadow-sm pixel-btn-active p-2 text-sm font-mono text-secondary hover:text-ink transition-colors"
      aria-label={theme === "light" ? "切换暗色模式" : "切换亮色模式"}
    >
      {theme === "light" ? "🌙" : "☀️"}
    </button>
  );
}
