"use client";

export default function GlobalError({
  error,
  unstable_retry,
}: {
  error: Error & { digest?: string };
  unstable_retry: () => void;
}) {
  return (
    <html lang="zh-CN">
      <body className="flex min-h-screen items-center justify-center bg-canvas">
        <div className="rounded bg-surface px-8 py-6 text-center pixel-border pixel-shadow-sm">
          <h2 className="pixel-heading text-2xl text-ink">应用出错了</h2>
          <p className="mt-2 text-muted">
            {error.digest ? `错误代码: ${error.digest}` : "发生了严重错误"}
          </p>
          <button
            onClick={() => unstable_retry()}
            className="mt-4 rounded bg-primary px-4 py-2 text-primary-text pixel-shadow-sm pixel-btn-active hover:bg-primary-hover"
          >
            重试
          </button>
        </div>
      </body>
    </html>
  );
}
