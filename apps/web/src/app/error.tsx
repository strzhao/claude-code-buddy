"use client";

import { useEffect } from "react";

export default function Error({
  error,
  unstable_retry,
}: {
  error: Error & { digest?: string };
  unstable_retry: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-4">
      <h2 className="pixel-heading text-xl text-ink">出错了</h2>
      <p className="text-muted">{error.digest ? `错误代码: ${error.digest}` : "发生了意外错误"}</p>
      <button
        onClick={() => unstable_retry()}
        className="rounded bg-primary px-4 py-2 text-primary-text pixel-shadow-sm pixel-btn-active hover:bg-primary-hover"
      >
        重试
      </button>
    </div>
  );
}
