---
id: "007-hotswap"
depends_on: ["003-refactor-animation", "004-refactor-scene", "005-refactor-food", "006-refactor-menubar"]
---

# 007: 热替换机制 + AppDelegate 订阅

## 目标
运行时切换皮肤时，所有存活猫咪和 UI 元素立即更新，无需重启。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift` — 新增 `reloadSkin(_:)` 方法
- `Sources/ClaudeCodeBuddy/Entity/Cat/CatSprite.swift` — 新增 `reloadSkin(_:)` 方法
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` — 订阅 skinChanged + 分发
- `Sources/ClaudeCodeBuddy/MenuBar/MenuBarAnimator.swift` — 确保 reloadSprites() 已就绪（006 任务）

## 变更详情

### BuddyScene.reloadSkin(_ skin: SkinPack)
1. 重载边界装饰纹理（左右 boundary 节点）
2. 遍历每只活跃猫:
   a. `cat.node.removeAllActions()` — 清理所有动画 action
   b. `cat.containerNode.removeAction(forKey: "randomWalk")` — 清理移动 action
   c. `cat.containerNode.removeAction(forKey: "foodWalk")`
   d. `cat.animationComponent.loadTextures(from: skin)` — 重载纹理
   e. **CatEatingState 跳过**: `if cat.currentState == .eating { continue }` — 吃完自然切换
   f. **CatTaskCompleteState 特殊处理**: 调用 `reloadBedTexture(from:)` 更新床节点纹理
   g. `(cat.stateMachine.currentState as? ResumableState)?.resume()` — 重启动画
   h. 重新应用色彩染色 `node.color` + `node.colorBlendFactor`

### AppDelegate
- 新增 `private var cancellables = Set<AnyCancellable>()`
- 在 `applicationDidFinishLaunching` 中订阅:
  ```swift
  SkinPackManager.shared.skinChanged
      .receive(on: RunLoop.main)
      .sink { [weak self] skin in
          self?.scene?.reloadSkin(skin)
          self?.menuBarAnimator?.reloadSprites()
      }
      .store(in: &cancellables)
  ```

### 边缘情况
- 吃东西中的猫: 跳过热替换，eating done 后 switchState(to: .idle) 自然用新纹理
- 跳跃中的猫: 物理驱动的弧线继续，纹理已替换，落地后 resume 重启动画
- 正在退出场景的猫: exitScene walk action 会被清理，纹理替换后不影响退出流程
- 已生成的食物: 不回溯更新，新食物用新皮肤

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 手动测试: debug-A(idle) + debug-B(thinking) → 切换皮肤 → 两猫立即更新
- [ ] 菜单栏图标同步更新
- [ ] eating 状态的猫不崩溃（跳过后正常完成）
- [ ] taskComplete 状态的猫 bed 纹理更新
