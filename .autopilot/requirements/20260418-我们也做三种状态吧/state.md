---
active: false
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: true
knowledge_extracted: "skipped"
task_dir: "/Users/lilei03/netease-ai/ClaudeCodeBuddy/claude-code-buddy/.worktrees/rocket-step1/.autopilot/requirements/20260418-我们也做三种状态吧"
session_id: 
started_at: "2026-04-18T04:44:28Z"
---

## 目标
我们也做三种状态吧

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档
**目标**：菜单栏 rocket 三档与 cat 一致，每档对应明确语义。

- **idle (0 active)**：Raptors 熄火，星舰下沉 2pt（yShift=-2），无火焰、无运动、无烟雾
- **walk (1-2 active)**：星舰现状，small/medium 火焰交替 flicker（保持）
- **run (3+ active)**：Raptors 满推，5 帧全部 huge 火焰 + 3 条满条速度线；flicker/smoke 交替变化制造动态感

**技术方案**
- `drawRocket(ctx, yShift: Int = 0)` 增加位移参数；idle 调用 `drawRocket(ctx, yShift: -2)` 让船体+引擎+火焰锚点整体下移 2pt
- idle 帧不调用 drawFlame
- run 帧 plan 从 (large/huge 混搭) 改成全 huge，streak intensity 从 1-3 不等改成全部 3
- walk 不动

## 实现计划
- [x] drawRocket 增加 yShift 参数
- [x] idle 帧用 yShift=-2
- [x] run plan 改为 5 帧全 huge + 3 条速度线
- [x] 跑 generator 重生成 12 张 PNG
- [x] swift build 通过
- [x] app 重启 + morph rocket 验证日志

## QA 报告
**自动 tier**：build 通过；12 张 PNG 重新生成；app 启动 + morph rocket 无异常。视觉 tier 交用户目测。

## 变更日志
- [2026-04-18T04:44:28Z] autopilot 初始化
- [2026-04-18T04:47:00Z] auto_approve 一次跑完：drawRocket + yShift 参数 / idle 下沉 2pt / run 全 huge；phase → done
