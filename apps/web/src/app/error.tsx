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
      <h2 className="text-xl font-semibold">出错了</h2>
      <p className="text-gray-600">
        {error.digest ? `错误代码: ${error.digest}` : "发生了意外错误"}
      </p>
      <button
        onClick={() => unstable_retry()}
        className="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
      >
        重试
      </button>
    </div>
  );
}
