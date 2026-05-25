"use client";

import { useState, useCallback, useEffect } from "react";
import type { SkinRecord, SkinStatus } from "@/lib/types";
import StatusBadge from "./StatusBadge";

type TabValue = SkinStatus | "all";

const TABS: { label: string; value: TabValue }[] = [
  { label: "Pending", value: "pending" },
  { label: "Approved", value: "approved" },
  { label: "Rejected", value: "rejected" },
  { label: "All", value: "all" },
];

function compositeKey(id: string, version: string) {
  return `${id}:${version}`;
}

interface AdminDashboardProps {
  userEmail: string;
}

export default function AdminDashboard({ userEmail }: AdminDashboardProps) {
  const [activeTab, setActiveTab] = useState<TabValue>("pending");
  const [skins, setSkins] = useState<SkinRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [actionError, setActionError] = useState<string | null>(null);

  const fetchSkins = useCallback(async (status: TabValue) => {
    setLoading(true);
    setActionError(null);
    try {
      const res = await fetch(`/api/admin/skins?status=${status}`);
      if (!res.ok) {
        const body = await res.json();
        setActionError(body.error ?? "Failed to load skins.");
        setSkins([]);
      } else {
        const data = (await res.json()) as SkinRecord[];
        setSkins(data);
      }
    } catch {
      setActionError("Network error loading skins.");
      setSkins([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      if (!cancelled) {
        setLoading(true);
        setActionError(null);
      }
      try {
        const res = await fetch(`/api/admin/skins?status=${activeTab}`);
        if (cancelled) return;
        if (!res.ok) {
          const body = await res.json();
          setActionError(body.error ?? "Failed to load skins.");
          setSkins([]);
        } else {
          const data = (await res.json()) as SkinRecord[];
          setSkins(data);
        }
      } catch {
        if (!cancelled) {
          setActionError("Network error loading skins.");
          setSkins([]);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [activeTab]);

  function switchTab(tab: TabValue) {
    setActiveTab(tab);
    setSkins([]);
  }

  async function handleApprove(skin: SkinRecord) {
    const ck = encodeURIComponent(compositeKey(skin.id, skin.version));
    const res = await fetch(`/api/admin/skins/${ck}/approve`, {
      method: "POST",
    });
    if (!res.ok) {
      const body = await res.json();
      setActionError(body.error ?? "Approve failed.");
      return;
    }
    fetchSkins(activeTab);
  }

  async function handleReject(skin: SkinRecord) {
    const reason = window.prompt(`Rejection reason for "${skin.name}" (optional):`, "");
    if (reason === null) return; // cancelled
    const ck = encodeURIComponent(compositeKey(skin.id, skin.version));
    const res = await fetch(`/api/admin/skins/${ck}/reject`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reason }),
    });
    if (!res.ok) {
      const body = await res.json();
      setActionError(body.error ?? "Reject failed.");
      return;
    }
    fetchSkins(activeTab);
  }

  async function handleDelete(skin: SkinRecord) {
    if (
      !window.confirm(`Delete "${skin.name}" v${skin.version} permanently? This cannot be undone.`)
    ) {
      return;
    }
    const ck = encodeURIComponent(compositeKey(skin.id, skin.version));
    const res = await fetch(`/api/admin/skins/${ck}`, { method: "DELETE" });
    if (!res.ok) {
      const body = await res.json();
      setActionError(body.error ?? "Delete failed.");
      return;
    }
    fetchSkins(activeTab);
  }

  return (
    <div className="min-h-screen bg-canvas p-4 md:p-8">
      <div className="mx-auto max-w-5xl">
        {/* Header row */}
        <div className="mb-6 flex items-start justify-between gap-4">
          <div>
            <h1 className="mb-1 text-2xl font-semibold text-ink">Admin Dashboard</h1>
            <p className="text-sm text-muted">Review and manage submitted skin packs.</p>
          </div>
          {userEmail && (
            <div className="flex items-center gap-3 flex-shrink-0">
              <span className="text-sm text-muted">{userEmail}</span>
              <a
                href="/api/auth/logout"
                className="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-600 transition-colors hover:border-gray-400 hover:text-gray-800"
              >
                登出
              </a>
            </div>
          )}
        </div>

        {/* Tab bar */}
        <div className="mb-6 flex gap-0 rounded bg-surface pixel-border overflow-hidden w-fit">
          {TABS.map((tab) => (
            <button
              key={tab.value}
              onClick={() => switchTab(tab.value)}
              className={`px-5 py-2.5 text-sm font-medium transition-colors focus:outline-none ${
                activeTab === tab.value
                  ? "bg-primary text-primary-text"
                  : "text-secondary hover:bg-surface-alt hover:text-ink"
              }`}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {/* Action error */}
        {actionError && (
          <div className="mb-4 rounded border border-error bg-error-light px-4 py-3 text-sm text-error-text">
            {actionError}
            <button
              onClick={() => setActionError(null)}
              className="ml-3 underline hover:no-underline"
            >
              dismiss
            </button>
          </div>
        )}

        {/* Loading */}
        {loading && (
          <div className="flex items-center gap-2 text-sm text-muted">
            <Spinner />
            Loading…
          </div>
        )}

        {/* Empty state */}
        {!loading && skins.length === 0 && (
          <div className="rounded border-2 border-dashed border-border-strong bg-surface py-12 text-center text-sm text-muted">
            No {activeTab === "all" ? "" : activeTab} skins found.
          </div>
        )}

        {/* Skin cards */}
        {!loading && skins.length > 0 && (
          <div className="space-y-4">
            {skins.map((skin) => (
              <SkinCard
                key={compositeKey(skin.id, skin.version)}
                skin={skin}
                onApprove={handleApprove}
                onReject={handleReject}
                onDelete={handleDelete}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

interface SkinCardProps {
  skin: SkinRecord;
  onApprove: (skin: SkinRecord) => void;
  onReject: (skin: SkinRecord) => void;
  onDelete: (skin: SkinRecord) => void;
}

function SkinCard({ skin, onApprove, onReject, onDelete }: SkinCardProps) {
  return (
    <div className="rounded bg-surface pixel-border pixel-shadow-sm">
      <div className="flex gap-4 p-4">
        {/* Preview image */}
        {skin.preview_blob_url && (
          <div className="flex-shrink-0">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={skin.preview_blob_url}
              alt={`${skin.name} preview`}
              className="h-20 w-20 rounded border border-border object-contain bg-canvas pixel-render"
            />
          </div>
        )}

        {/* Info */}
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2 mb-1">
            <span className="font-semibold text-ink">{skin.name}</span>
            <StatusBadge status={skin.status} />
            <span className="text-xs text-muted">v{skin.version}</span>
          </div>
          <div className="text-sm text-secondary mb-1">
            by <span className="font-medium">{skin.author}</span>
          </div>
          <div className="flex flex-wrap gap-3 text-xs text-muted">
            <span>
              Canvas:{" "}
              <span className="font-mono">
                {skin.manifest.canvas_size[0]}x{skin.manifest.canvas_size[1]}
              </span>
            </span>
            <span>
              Animations: <span className="font-mono">{skin.manifest.animation_names.length}</span>
            </span>
            <span>
              ID: <span className="font-mono">{skin.id}</span>
            </span>
            <span>
              Size: <span className="font-mono">{(skin.size / 1024).toFixed(1)} KB</span>
            </span>
            <span>
              Submitted:{" "}
              {new Date(skin.created_at).toLocaleDateString(undefined, {
                year: "numeric",
                month: "short",
                day: "numeric",
              })}
            </span>
          </div>
          {skin.rejection_reason && (
            <p className="mt-1 text-xs text-error">Reason: {skin.rejection_reason}</p>
          )}
        </div>
      </div>

      {/* Manifest viewer */}
      <div className="border-t border-border px-4 pb-3 pt-2">
        <details className="group">
          <summary className="cursor-pointer select-none text-xs text-muted hover:text-secondary group-open:mb-2">
            View manifest JSON
          </summary>
          <pre className="overflow-x-auto rounded bg-canvas p-3 text-xs text-ink border border-border max-h-60">
            {JSON.stringify(skin.manifest, null, 2)}
          </pre>
        </details>
      </div>

      {/* Actions */}
      <div className="flex flex-wrap gap-2 border-t border-border px-4 py-3">
        {skin.status === "pending" && (
          <>
            <button
              onClick={() => onApprove(skin)}
              className="rounded bg-primary px-3 py-1.5 text-xs font-medium text-primary-text transition-colors hover:bg-primary-hover focus:outline-none focus:ring-2 focus:ring-focus focus:ring-offset-1 pixel-shadow-sm pixel-btn-active"
            >
              Approve
            </button>
            <button
              onClick={() => onReject(skin)}
              className="rounded bg-error px-3 py-1.5 text-xs font-medium text-primary-text transition-colors hover:bg-error hover:brightness-90 focus:outline-none focus:ring-2 focus:ring-focus focus:ring-offset-1 pixel-shadow-sm pixel-btn-active"
            >
              Reject
            </button>
          </>
        )}
        <button
          onClick={() => onDelete(skin)}
          className="rounded border border-border-strong bg-surface px-3 py-1.5 text-xs font-medium text-secondary transition-colors hover:border-border-strong hover:text-ink focus:outline-none focus:ring-2 focus:ring-focus focus:ring-offset-1 pixel-shadow-sm pixel-btn-active"
        >
          Delete
        </button>
      </div>
    </div>
  );
}

function Spinner() {
  return (
    <svg
      className="h-4 w-4 animate-spin text-muted"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path
        className="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
      />
    </svg>
  );
}
