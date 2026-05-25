import { ThemeToggle } from "@/components/ThemeToggle";
import HeroSection from "@/components/landing/HeroSection";
import FeaturesSection from "@/components/landing/FeaturesSection";
import InstallSection from "@/components/landing/InstallSection";
import SkinsSection from "@/components/landing/SkinsSection";
import ScrollReveal from "@/components/landing/ScrollReveal";
import Footer from "@/components/landing/Footer";

export default function Home() {
  return (
    <>
      <nav className="fixed top-0 left-0 right-0 z-50 flex items-center justify-between px-6 py-3 bg-canvas/80 backdrop-blur-sm">
        <span className="pixel-heading text-lg text-ink">Claude Code Buddy</span>
        <ThemeToggle />
      </nav>
      <main className="flex-1 pt-14">
        <HeroSection />
        <ScrollReveal>
          <FeaturesSection />
        </ScrollReveal>
        <ScrollReveal>
          <InstallSection />
        </ScrollReveal>
        <ScrollReveal>
          <SkinsSection />
        </ScrollReveal>
      </main>
      <Footer />
    </>
  );
}
