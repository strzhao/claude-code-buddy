---
name: click-handler-delegate-to-scene
description: 点击事件回调不应在 AppDelegate 中重复实现场景逻辑 —— 委托给 scene.simulateClick，防止逻辑分叉
metadata:
  type: pattern
  tags: appkit, click-handler, delegate, scene, simulateClick, onclick, mousetracker, appdelegate, buddy-scene, divergence, dedup
---

# 点击事件回调委托给场景方法，避免逻辑分叉

**问题**：`AppDelegate.setupWindow()` 中 `tracker.onClick` 闭包手动调用 `scene.acknowledgePermission` + `scene.removePersistentBadge` + 终端激活，与 `BuddyScene.simulateClick(sessionId:)` 中的逻辑**重复但不同步**。`simulateClick` 包含更新徽章检查（`cat.updateBadgeNode != nil`），但 onClick 闭包未包含这段逻辑。结果：真实鼠标点击永远不会触发更新升级流程（更新徽章点击无反应），而 `buddy click` CLI 命令（走 `simulateClick`）可以。

**根因**：两个入口（鼠标点击 vs CLI click）本应走同一代码路径，但因 AppDelegate 中手动复刻了 scene 逻辑导致分叉。

**修复**：`tracker.onClick` 闭包改为调用 `scene?.simulateClick(sessionId:)`，删除其中重复的 ack/removePersistentBadge 逻辑。`simulateClick` 成为点击处理的**单一入口**。终端激活等 AppDelegate 特有逻辑保留在 onClick 回调的 simulateClick 之后执行。

**Why**: 鼠标点击和 CLI click 应走同一代码路径，重复实现必然导致逻辑分叉。场景方法是单一真相源，AppDelegate 回调应委托而非复制。

**How to apply**: 新增点击交互逻辑时，先问：这个逻辑是否已在 `simulateClick` 中实现？如果是，AppDelegate 回调直接委托；如果不是，先在 `simulateClick` 中添加，再让所有入口调用。

**相关记忆**: [[buddy-scene-simulateClick-single-entry]]
