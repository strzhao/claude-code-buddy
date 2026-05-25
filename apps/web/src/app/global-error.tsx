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
      <body className="flex min-h-screen items-center justify-center bg-gray-50">
        <div className="text-center">
          <h2 className="text-2xl font-bold text-gray-900">应用出错了</h2>
          <p className="mt-2 text-gray-600">
            {error.digest ? `错误代码: ${error.digest}` : "发生了严重错误"}
          </p>
          <button
            onClick={() => unstable_retry()}
            className="mt-4 rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
          >
            重试
          </button>
        </div>
      </body>
    </html>
  );
}
