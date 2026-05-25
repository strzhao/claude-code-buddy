import type { Metadata } from "next";
import ColorsShowcase from "@/components/ColorsShowcase";

export const metadata: Metadata = {
  title: "Color System — Claude Code Buddy",
  description: "Pixel-art design system colors, tokens, and component showcase",
};

export default function ColorsPage() {
  return <ColorsShowcase />;
}
