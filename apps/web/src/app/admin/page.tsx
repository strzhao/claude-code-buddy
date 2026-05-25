import type { Metadata } from "next";
import { cookies } from "next/headers";
import AdminDashboard from "@/components/AdminDashboard";
import { GATEWAY_COOKIE_NAME, extractEmailFromSession } from "@/lib/auth";

export const metadata: Metadata = {
  title: "Admin — Claude Code Buddy Skin Store",
};

export default async function AdminPage() {
  const cookieStore = await cookies();
  const sessionValue = cookieStore.get(GATEWAY_COOKIE_NAME)?.value ?? "";
  const userEmail = extractEmailFromSession(sessionValue) ?? "";

  return <AdminDashboard userEmail={userEmail} />;
}
