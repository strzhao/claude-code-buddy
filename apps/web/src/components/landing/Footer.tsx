import Link from "next/link";

export default function Footer() {
  return (
    <footer className="bg-surface-alt py-8">
      <hr className="pixel-divider mb-8" />
      <div className="max-w-4xl mx-auto px-6">
        <nav className="flex flex-wrap justify-center gap-x-8 gap-y-3 mb-6">
          <a
            href="https://github.com/strzhao/claude-code-buddy"
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted hover:text-ink transition-colors text-sm"
          >
            GitHub
          </a>
          <Link href="/upload" className="text-muted hover:text-ink transition-colors text-sm">
            皮肤上传
          </Link>
          <Link href="/admin" className="text-muted hover:text-ink transition-colors text-sm">
            管理后台
          </Link>
          <a
            href="/api/skins"
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted hover:text-ink transition-colors text-sm"
          >
            API 文档
          </a>
        </nav>
        <p className="text-center text-muted text-xs">由 Claude Code 驱动 · macOS 14+</p>
      </div>
    </footer>
  );
}
