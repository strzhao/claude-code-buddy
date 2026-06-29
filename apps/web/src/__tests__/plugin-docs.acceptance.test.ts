/**
 * 验收测试：web /plugin/docs 文档页 —— AI 开发指南常量内容契约（契约 C7）
 *
 * 黑盒验证 plugin-dev-guide.ts 的 PLUGIN_DEV_GUIDE 常量含全部要素。
 *
 * 覆盖验收场景：
 * - 场景 7.P2: 页面含关键章节（plugin.json schema、stdin/command/prompt 三 mode、安装、社区）
 * - 场景 8.P1: 指南文本含全部要素（schema、三 mode、最小示例、调试、安装、合入社区）
 *   assert: 命中 `buddy launcher add`、`buddy launcher run`、`.disabled`、`marketplace`/`社区`
 *
 * 信息隔离：不读页面组件实现，仅 import 契约 C7 声明的 PLUGIN_DEV_GUIDE 常量断言内容。
 * 页面渲染（HTTP 200 / 复制按钮 DOM）属 det-machine curl 范畴（场景 7.P1/P3），由 QA 真实 curl 覆盖。
 *
 * 命名前缀: test_AT<编号>_<场景>
 */

import { describe, it, expect } from "vitest";
import { PLUGIN_DEV_GUIDE } from "@/content/plugin-dev-guide";

describe("PluginDevGuide 常量内容契约 (C7)", () => {
  // 缓存为小写便于大小写不敏感断言
  const lower = (): string => PLUGIN_DEV_GUIDE.toLowerCase();

  // MARK: - 场景 7.P2: 关键章节（plugin.json schema、三 mode、安装、社区）

  it("test_AT01_containsPluginJSONSchemaSection", () => {
    // 场景 7.P2 assert: grep 'plugin\.json' 至少 1 次
    expect(PLUGIN_DEV_GUIDE).toMatch(/plugin\.json/i);
  });

  it("test_AT02_containsAllThreeModes", () => {
    // 场景 7.P2 assert: stdin/command/prompt 每项至少 1 次
    const text = lower();
    expect(text).toContain("stdin");
    expect(text).toContain("command");
    expect(text).toContain("prompt");
  });

  it("test_AT03_containsInstallSection", () => {
    // 场景 7.P2 assert: 安装 至少 1 次
    expect(PLUGIN_DEV_GUIDE).toMatch(/安装/);
  });

  it("test_AT04_containsCommunitySection", () => {
    // 场景 7.P2 assert: 社区 至少 1 次
    expect(PLUGIN_DEV_GUIDE).toMatch(/社区/);
  });

  // MARK: - 场景 8.P1: 指南含全部要素（schema、三 mode、最小示例、调试、安装、合入社区）

  it("test_AT05_containsBuddyLauncherAddCommand", () => {
    // 场景 8.P1 assert: 命中 `buddy launcher add`
    expect(lower()).toContain("buddy launcher add");
  });

  it("test_AT06_containsBuddyLauncherRunCommand", () => {
    // 场景 8.P1 assert: 命中 `buddy launcher run`
    expect(lower()).toContain("buddy launcher run");
  });

  it("test_AT07_containsDisabledToggleMechanism", () => {
    // 场景 8.P1 assert: 命中 `.disabled`
    expect(PLUGIN_DEV_GUIDE).toContain(".disabled");
  });

  it("test_AT08_containsMarketplaceReference", () => {
    // 场景 8.P1 assert: 命中 `marketplace`
    expect(lower()).toContain("marketplace");
  });

  // MARK: - 契约 C7: 10 节完整性（间接要素）

  it("test_AT09_containsSummaryDescriptionWritingGuide", () => {
    // 契约 C7 第⑩节：summary/description 写作规范
    const text = lower();
    expect(text).toContain("summary");
    expect(text).toContain("description");
  });

  it("test_AT10_containsDebuggingSection", () => {
    // 契约 C7 第⑥节：开发与调试（buddy log show --subsystem plugin + buddy launcher inspect/list）
    const text = lower();
    // 调试章节应至少提及 log 或 inspect
    const hasDebug =
      text.includes("buddy log") || text.includes("调试") || text.includes("inspect");
    expect(hasDebug, "指南必须含调试章节（buddy log / 调试 / inspect）").toBe(true);
  });

  it("test_AT11_containsMinimalExampleSection", () => {
    // 契约 C7 第⑤节：最小示例（hello 模板）
    const text = lower();
    const hasExample = text.includes("hello") || text.includes("示例") || text.includes("模板");
    expect(hasExample, "指南必须含最小示例章节（hello/示例/模板）").toBe(true);
  });

  it("test_AT12_containsSecurityModelSection", () => {
    // 契约 C7 第⑨节：安全模型（TOFU/requiredPath/路径限制）
    const text = lower();
    const hasSecurity =
      text.includes("tofu") ||
      text.includes("trust") ||
      text.includes("信任") ||
      text.includes("requiredpath") ||
      text.includes("安全");
    expect(hasSecurity, "指南必须含安全模型章节（TOFU/trust/信任/requiredPath/安全）").toBe(true);
  });

  it("test_AT13_guideIsSubstantialSelfContained", () => {
    // 契约 C7: 自包含完整指南 —— 不能是占位空串。最低长度信号（PLUGIN_DEV_GUIDE.length ≥ 200）。
    // 注：vitest matcher 仅接受 1 个参数，原内联 message 会触发 TS2554 并阻断 CI Type check。
    expect(PLUGIN_DEV_GUIDE.length).toBeGreaterThanOrEqual(200);
    // 同时确保非纯空白
    expect(PLUGIN_DEV_GUIDE.trim().length).toBeGreaterThan(0);
  });
});
