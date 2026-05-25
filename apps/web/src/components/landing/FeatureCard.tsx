import type { ReactNode } from "react";

interface FeatureCardProps {
  icon: ReactNode;
  title: string;
  description: string;
}

export default function FeatureCard({ icon, title, description }: FeatureCardProps) {
  return (
    <div className="bg-surface rounded pixel-border pixel-shadow-sm p-5">
      <div className="flex items-center justify-center w-12 h-12 mb-4">{icon}</div>
      <h3 className="pixel-heading text-lg mb-2 text-ink">{title}</h3>
      <p className="text-secondary text-sm leading-relaxed">{description}</p>
    </div>
  );
}
