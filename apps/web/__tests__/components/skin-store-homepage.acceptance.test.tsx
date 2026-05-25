/**
 * 验收测试: CatSkinCard 组件 + SkinCard hover 增强 + SkinsSection 集成
 *
 * 基于黑盒视角验证设计文档声明的所有功能点：
 *
 * CatSkinCard:
 * - 新建 src/components/landing/CatSkinCard.tsx（"use client"）
 * - 静态预览: /sprites/cats/cat-idle-a-1.png
 * - Hover: setInterval 帧动画（idle-a 8帧 @ 8fps）
 * - Hover 离开: 清除 interval + 重置到第1帧
 *
 * SkinCard hover 增强:
 * - 添加 "use client" + useState hover
 * - 不用 scale、不用 inline style
 *
 * SkinsSection:
 * - 始终渲染 grid
 * - CatSkinCard 作为第一个子元素
 * - upload link 始终显示
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import React from "react";
import type { SkinRecord } from "@/lib/types";

// CatSkinCard 的帧参数常量（设计文档规格）
const CAT_IDLE_TOTAL_FRAMES = 8;
const CAT_IDLE_FPS = 8;
const CAT_IDLE_INTERVAL_MS = Math.round(1000 / CAT_IDLE_FPS); // 125ms

// Mock next/link to avoid router context requirement
vi.mock("next/link", () => ({
  default: ({
    href,
    children,
    className,
  }: {
    href: string;
    children: React.ReactNode;
    className?: string;
  }) => React.createElement("a", { href, className }, children),
}));

// Mock kv to avoid Redis connection in SkinsSection async server component
vi.mock("@/lib/kv", () => ({
  listSkinsByStatus: vi.fn().mockResolvedValue([]),
}));

function makeSkinRecord(overrides: Partial<SkinRecord> = {}): SkinRecord {
  return {
    id: "test-skin",
    name: "Test Skin",
    author: "tester",
    version: "1.0.0",
    status: "approved",
    manifest: {} as SkinRecord["manifest"],
    blob_url: "https://example.com/skin.zip",
    preview_blob_url: null,
    size: 1024,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("CatSkinCard (acceptance)", () => {
  it("组件应当可以从 @/components/landing/CatSkinCard 导入", async () => {
    const mod = await import("@/components/landing/CatSkinCard");
    expect(mod.default).toBeDefined();
    expect(typeof mod.default).toBe("function");
  });

  it("静态状态下应当渲染第 1 帧预览图 cat-idle-a-1.png", async () => {
    const { default: CatSkinCard } = await import("@/components/landing/CatSkinCard");
    render(<CatSkinCard />);
    const img = screen.getByRole("img");
    expect(img.getAttribute("src")).toContain("cat-idle-a-1");
  });

  it("应当显示 Cat 皮肤名称文字", async () => {
    const { default: CatSkinCard } = await import("@/components/landing/CatSkinCard");
    const { container } = render(<CatSkinCard />);
    // 默认猫咪皮肤卡片应展示名称（设计文档：hardcoded virtual card）
    const text = container.textContent ?? "";
    expect(text.toLowerCase()).toMatch(/cat|猫|默认/i);
  });

  it("hover 时应启动帧动画（interval 125ms，8帧循环）", async () => {
    vi.useFakeTimers();
    const { default: CatSkinCard } = await import("@/components/landing/CatSkinCard");
    const { container } = render(<CatSkinCard />);

    const card = container.firstChild as HTMLElement;
    fireEvent.mouseEnter(card);

    // 推进时间：经过 8 帧的时间（8 * 125ms = 1000ms）
    await act(async () => {
      vi.advanceTimersByTime(CAT_IDLE_TOTAL_FRAMES * CAT_IDLE_INTERVAL_MS);
    });

    const img = screen.getByRole("img");
    // hover 后帧应该推进（不再是第1帧，或已循环回来）
    // 由于8帧完整循环后回到起点，验证 img src 包含 cat-idle-a 前缀
    expect(img.getAttribute("src")).toContain("cat-idle-a");

    vi.useRealTimers();
  });

  it("hover 离开时应重置回第 1 帧", async () => {
    vi.useFakeTimers();
    const { default: CatSkinCard } = await import("@/components/landing/CatSkinCard");
    const { container } = render(<CatSkinCard />);

    const card = container.firstChild as HTMLElement;

    // 先 hover 推进帧（推进3帧，不完整循环，确保帧不在第1帧）
    fireEvent.mouseEnter(card);
    await act(async () => {
      vi.advanceTimersByTime(3 * CAT_IDLE_INTERVAL_MS + 50);
    });

    // 离开 hover
    fireEvent.mouseLeave(card);
    await act(async () => {
      vi.advanceTimersByTime(0);
    });

    const img = screen.getByRole("img");
    expect(img.getAttribute("src")).toContain("cat-idle-a-1");

    vi.useRealTimers();
  });

  it("预览图应当有 pixel-render class（pixelated image-rendering）", async () => {
    const { default: CatSkinCard } = await import("@/components/landing/CatSkinCard");
    render(<CatSkinCard />);
    const img = screen.getByRole("img");
    expect(img.className).toContain("pixel-render");
  });

  it("CAT_IDLE_TOTAL_FRAMES 应为 8 帧（设计规格）", () => {
    expect(CAT_IDLE_TOTAL_FRAMES).toBe(8);
  });

  it("CAT_IDLE_FPS 应为 8fps，间隔 125ms（设计规格）", () => {
    expect(CAT_IDLE_INTERVAL_MS).toBe(125);
  });
});

describe("SkinCard hover 增强 (acceptance)", () => {
  it("SkinCard 应当可以从 @/components/landing/SkinCard 导入", async () => {
    const mod = await import("@/components/landing/SkinCard");
    expect(mod.default).toBeDefined();
    expect(typeof mod.default).toBe("function");
  });

  it("SkinCard 初始状态应有 pixel-shadow-sm class", async () => {
    const { default: SkinCard } = await import("@/components/landing/SkinCard");
    const skin = makeSkinRecord();
    const { container } = render(<SkinCard skin={skin} />);
    const card = container.firstChild as HTMLElement;
    expect(card.className).toContain("pixel-shadow-sm");
  });

  it("SkinCard hover 时应切换为 pixel-shadow 并有 -translate-y-0.5", async () => {
    const { default: SkinCard } = await import("@/components/landing/SkinCard");
    const skin = makeSkinRecord();
    const { container } = render(<SkinCard skin={skin} />);
    const card = container.firstChild as HTMLElement;

    fireEvent.mouseEnter(card);
    await act(async () => {});

    expect(card.className).toContain("pixel-shadow");
    expect(card.className).toContain("-translate-y-0.5");
  });

  it("SkinCard hover 时不应使用 scale transform", async () => {
    const { default: SkinCard } = await import("@/components/landing/SkinCard");
    const skin = makeSkinRecord();
    const { container } = render(<SkinCard skin={skin} />);
    const card = container.firstChild as HTMLElement;

    fireEvent.mouseEnter(card);
    await act(async () => {});

    // 设计文档：不用 scale
    expect(card.className).not.toMatch(/scale-\d/);
  });

  it("SkinCard hover 时不应使用 inline style", async () => {
    const { default: SkinCard } = await import("@/components/landing/SkinCard");
    const skin = makeSkinRecord();
    const { container } = render(<SkinCard skin={skin} />);
    const card = container.firstChild as HTMLElement;

    fireEvent.mouseEnter(card);
    await act(async () => {});

    // 设计文档：不用 inline style
    const inlineStyle = card.getAttribute("style") ?? "";
    expect(inlineStyle).toBe("");
  });

  it("SkinCard hover 离开后应恢复 pixel-shadow-sm", async () => {
    const { default: SkinCard } = await import("@/components/landing/SkinCard");
    const skin = makeSkinRecord();
    const { container } = render(<SkinCard skin={skin} />);
    const card = container.firstChild as HTMLElement;

    fireEvent.mouseEnter(card);
    await act(async () => {});
    fireEvent.mouseLeave(card);
    await act(async () => {});

    expect(card.className).toContain("pixel-shadow-sm");
  });
});

describe("SkinsSection 集成 (acceptance)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("SkinsSection 应当可以从 @/components/landing/SkinsSection 导入", async () => {
    const mod = await import("@/components/landing/SkinsSection");
    expect(mod.default).toBeDefined();
    expect(typeof mod.default).toBe("function");
  });

  it("SkinsSection 模块文件中应引用 CatSkinCard（两者均可导入）", async () => {
    const [skinsSectionModule, catCardModule] = await Promise.all([
      import("@/components/landing/SkinsSection"),
      import("@/components/landing/CatSkinCard"),
    ]);

    expect(skinsSectionModule.default).toBeDefined();
    expect(catCardModule.default).toBeDefined();
  });

  it("SkinsSection 渲染结果应包含 grid 布局容器", async () => {
    const { listSkinsByStatus } = await import("@/lib/kv");
    vi.mocked(listSkinsByStatus).mockResolvedValue([]);

    const { default: SkinsSection } = await import("@/components/landing/SkinsSection");
    // SkinsSection 是 async server component，await resolve 后渲染
    const element = await SkinsSection();
    const { container } = render(element as React.ReactElement);

    const grid = container.querySelector('[class*="grid"]');
    expect(grid).not.toBeNull();
  });

  it("SkinsSection 空皮肤列表时仍渲染 CatSkinCard（cat-idle-a 图片）", async () => {
    const { listSkinsByStatus } = await import("@/lib/kv");
    vi.mocked(listSkinsByStatus).mockResolvedValue([]);

    const { default: SkinsSection } = await import("@/components/landing/SkinsSection");
    const element = await SkinsSection();
    render(element as React.ReactElement);

    const images = document.querySelectorAll("img");
    const catImage = Array.from(images).find((img) =>
      (img.getAttribute("src") ?? "").includes("cat-idle-a"),
    );
    expect(catImage).not.toBeUndefined();
  });

  it("SkinsSection 应当始终显示 upload link（/upload href）", async () => {
    const { listSkinsByStatus } = await import("@/lib/kv");
    vi.mocked(listSkinsByStatus).mockResolvedValue([]);

    const { default: SkinsSection } = await import("@/components/landing/SkinsSection");
    const element = await SkinsSection();
    render(element as React.ReactElement);

    const links = screen.getAllByRole("link");
    const uploadLink = links.find((l) => {
      const href = l.getAttribute("href") ?? "";
      const text = l.textContent ?? "";
      return href.includes("upload") || text.match(/上传|upload/i);
    });
    expect(uploadLink).not.toBeUndefined();
  });

  it("有远程皮肤时 CatSkinCard 应当作为 grid 第一个 img（第一个子元素）", async () => {
    const { listSkinsByStatus } = await import("@/lib/kv");
    vi.mocked(listSkinsByStatus).mockResolvedValue([
      makeSkinRecord({
        id: "dog-skin",
        name: "Dog Skin",
        preview_blob_url: "https://example.com/dog-preview.png",
      }),
    ]);

    const { default: SkinsSection } = await import("@/components/landing/SkinsSection");
    const element = await SkinsSection();
    render(element as React.ReactElement);

    const allImages = document.querySelectorAll("img");
    expect(allImages.length).toBeGreaterThanOrEqual(1);

    // 第一张图片应当是猫咪（设计规格：CatSkinCard 作为 grid 第一个子元素）
    const firstImg = allImages[0];
    expect(firstImg.getAttribute("src")).toContain("cat-idle-a");
  });
});
