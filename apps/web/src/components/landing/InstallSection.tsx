import CodeBlock from "@/components/landing/CodeBlock";

const steps = [
  {
    number: 1,
    label: "Homebrew",
    command: "brew tap strzhao/claude-code-buddy && brew install claude-code-buddy",
  },
  {
    number: 2,
    label: "安装插件",
    command: "/plugin marketplace add strzhao/claude-code-buddy",
  },
  {
    number: 3,
    label: "激活插件",
    command: "/plugin install claude-code-buddy-hooks && /reload-plugins",
  },
];

export default function InstallSection() {
  return (
    <section id="install" className="py-16 px-6">
      <div className="max-w-2xl mx-auto">
        <h2 className="pixel-heading text-3xl text-ink mb-2">安装指南</h2>
        <p className="text-muted mb-10">两步搞定，马上开始</p>
        <div className="space-y-8">
          {steps.map((step) => (
            <div key={step.number} className="flex gap-4">
              <div className="flex-shrink-0 w-8 h-8 bg-primary text-primary-text pixel-border rounded flex items-center justify-center font-mono font-bold text-sm">
                {step.number}
              </div>
              <div className="flex-1 min-w-0">
                <p className="pixel-heading text-sm text-secondary mb-2">{step.label}</p>
                <CodeBlock label="" command={step.command} />
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
