import Image from "next/image";
import FeatureCard from "@/components/landing/FeatureCard";

const features = [
  {
    icon: (
      <Image
        src="/sprites/cats/cat-scared-1.png"
        alt="通知猫咪"
        width={48}
        height={48}
        unoptimized
        className="pixel-render w-12 h-12"
      />
    ),
    title: "智能通知",
    description:
      "不用盯着终端 — 需要授权时猫咪变红震动+声音提醒，任务完成时回窝睡觉。点击猫咪一键跳转到对应终端",
  },
  {
    icon: (
      <svg viewBox="0 0 48 48" className="w-12 h-12" fill="none">
        <rect
          x="4"
          y="8"
          width="40"
          height="32"
          rx="4"
          className="stroke-primary"
          strokeWidth="3"
        />
        <text
          x="24"
          y="28"
          textAnchor="middle"
          className="fill-primary"
          fontSize="11"
          fontFamily="monospace"
          fontWeight="bold"
        >
          0.3M
        </text>
        <circle cx="12" cy="16" r="3" className="fill-primary" opacity="0.5" />
      </svg>
    ),
    title: "Token 监控",
    description: "菜单栏实时查看每个会话的模型、时长、Token 消耗和工具调用次数。再也不怕预算超标",
  },
  {
    icon: (
      <Image
        src="/sprites/cats/cat-idle-a-1.png"
        alt="空闲猫咪"
        width={48}
        height={48}
        unoptimized
        className="pixel-render w-12 h-12"
      />
    ),
    title: "实时陪伴",
    description:
      "每个 Claude Code 会话对应一只猫咪。空闲时打盹，思考时摇尾巴，写代码时来回奔跑。多会话多只猫共存",
  },
  {
    icon: (
      <Image
        src="/sprites/food/81_pizza.png"
        alt="像素披萨"
        width={48}
        height={48}
        unoptimized
        className="pixel-render w-12 h-12"
      />
    ),
    title: "自定义皮肤",
    description: "不喜欢橘猫？社区皮肤包让伴侣千变万化 — 连音效都能自定义",
  },
];

export default function FeaturesSection() {
  return (
    <section id="features" className="py-16 px-6">
      <div className="max-w-5xl mx-auto">
        <h2 className="pixel-heading text-3xl text-ink mb-3 text-center">为什么选择 Buddy</h2>
        <p className="text-muted text-center mb-10 max-w-xl mx-auto">
          不只是桌面宠物 — 它是你和 Claude Code 之间的智能桥梁
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5">
          {features.map((feature) => (
            <FeatureCard
              key={feature.title}
              icon={feature.icon}
              title={feature.title}
              description={feature.description}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
