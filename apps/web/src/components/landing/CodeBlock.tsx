"use client";

import { useState } from "react";

interface CodeBlockProps {
  label: string;
  command: string;
}

export default function CodeBlock({ label, command }: CodeBlockProps) {
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(command);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="relative">
      {label && <p className="text-muted text-xs mb-1 font-mono">{label}</p>}
      <pre className="bg-surface-alt pixel-border rounded font-mono text-sm p-4 pr-20 overflow-x-auto text-ink whitespace-pre-wrap break-all">
        {command}
      </pre>
      <button
        onClick={handleCopy}
        className="absolute top-2 right-2 bg-surface pixel-border pixel-btn-active text-secondary text-xs px-2 py-1 rounded transition-colors hover:text-ink"
        aria-label="复制命令"
      >
        {copied ? "已复制" : "复制"}
      </button>
    </div>
  );
}
