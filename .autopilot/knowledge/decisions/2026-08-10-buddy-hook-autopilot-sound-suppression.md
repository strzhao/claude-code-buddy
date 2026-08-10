<!-- tags: hook, buddy-hook, autopilot, sound, stop, notify, active-ptr, idle, worktree, design -->
# autopilot session 抑制过渡 Stop 完成音

## 背景
autopilot 用 Stop hook 的 `decision:block` 做阶段状态机循环（design→implement→qa→merge→auto-chain）。绝大多数 Stop 是"过渡"（block 注入下一阶段 prompt），仅 phase=done 放行 / 审批门 / max_iter 是"真停止"。buddy 的 Stop hook 无条件 `Stop → task_complete → SoundManager 播完成音`，导致 autopilot 每个阶段过渡响一次无效完成音（一个任务响十几次）。

## 决策：声音触发源从 Stop 迁移到 notify.sh
- **buddy-hook.sh**：Stop 时检测 cwd 下 `.autopilot/runtime/active.ptr`（`os.path.isfile` + worktree `sessions/*/active.ptr` glob isfile），命中则 `event = "idle"`（不响完成音、猫不进完成态）。非 autopilot 场景行为逐字不变。三处同步（plugin/scripts + hooks + cache）。
- **notify.sh**（autopilot 仓库）：智能化 SOUND 分支——`auto-chain` / `project-qa` 静默（纯过渡不打断），`complete` / `project-complete` / `review-accept` / `error` / `project-design-complete` 发声（Glass）。文字通知全部保留。

## 为什么不复刻 autopilot 状态机
可靠区分信号（这次 Stop 会 block 还是放行）在 autopilot 内部（读 state.md 的 phase/gate 后才知道），buddy 作为同步触发的独立 hook 看不到。完整复刻状态机会强耦合，且 autopilot 自身改了三版才修对（flag-asymmetry / 状态切换重读教训，见 stop-hook-state-machine domain）。`active.ptr` 是"autopilot 活跃中"的廉价代理信号——buddy 让位（过渡不响）+ notify 智能化（真完成才响）= 声音职责归位，零状态机复刻。

## 为什么 event=idle 而非新增事件
idle 是猫咪默认空闲态。Stop→idle→（block 后）thinking 比 Stop→task_complete→thinking 自然——不会闪一下完成态再回到工作态。

## 否决的方案
- **短去抖 + 后续事件取消**：实测过渡 Stop 后到下一可观测事件间隔 **11–61s**（block 注入的是"读 state.md + 起 sub-agent"重 prompt，主 agent 唤醒慢）。去抖窗口要么 <11s 抓不到过渡，要么 ≥60s 让真完成也等不起。否决。
- **全静音 autopilot session**：砍掉功能来"解决"问题——真完成也不响，插件价值归零。否决。
- **改 task-notifier**：源码仓库有 task-notifier 插件，但用户根本没装（cache/settings 均无），声音源只有 buddy。方案比预想简单。

## 教训
- 诊断"无效声音"先确认声音源——以为是 subagent stop / task-notifier，实测只有 buddy。见 [[root-cause-before-fixes]]。
- 同一 Stop 事件多个独立 hook 各自盲目响应是跨工具噪音的常见来源；让"该不该响应"由真正知道答案的一方（autopilot notify）决定。
