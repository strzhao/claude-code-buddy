import type { Metadata } from "next";
import UploadForm from "@/components/UploadForm";

export const metadata: Metadata = {
  title: "Upload Skin Pack — Claude Code Buddy",
};

export default function UploadPage() {
  return (
    <main className="min-h-screen flex items-center justify-center p-4 bg-canvas">
      <UploadForm />
    </main>
  );
}
