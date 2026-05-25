import type { SkinStatus } from "@/lib/types";

const STATUS_STYLES: Record<SkinStatus, string> = {
  pending: "bg-warning-light text-warning-text border-warning",
  approved: "bg-success-light text-success-text border-success",
  rejected: "bg-error-light text-error-text border-error",
};

interface StatusBadgeProps {
  status: SkinStatus;
}

export default function StatusBadge({ status }: StatusBadgeProps) {
  return (
    <span
      className={`inline-flex items-center rounded border-2 px-2 py-0.5 font-mono text-[10px] font-medium uppercase tracking-wider ${STATUS_STYLES[status]}`}
    >
      {status}
    </span>
  );
}
