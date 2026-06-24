## 探索的目的与约束

**目标**：优化自动升级功能的用户体验 —— 将升级流程移入设置 > 关于页面，增加实时进度反馈，用单只系统猫替代全猫徽章，支持版本去重（点击后不再提示同一版本）。

**项目上下文关键发现**：

1. **现有关键 bug**：`AppDelegate.onClick`（line 138-161）直接调用 `acknowledgePermission` + `removePersistentBadge` + 终端激活，**完全绕过了** `BuddyScene.simulateClick(sessionId:)`（line 844-858），后者才包含更新徽章检查逻辑。`simulateClick` 目前仅被 `buddy click` CLI 命令和测试调用。这是点击绿色圆圈无反应的根因。

2. **现有架构**：`UpdateChecker` 单例（~200 行），通过 GitHub Releases API 24h 轮询，brew upgrade 执行升级，EventBus 发布 `updateAvailable` / `upgradeCompleted` 事件。

3. **设置窗口**：`NSSplitViewController` + sidebar 导航，`AboutSettingsViewController` 当前仅显示图标、名称、版本、反馈/开源按钮。加新 UI 组件遵循现有 Auto Layout + SettingsTheme token 体系。

4. **场景层**：`BuddyScene` 管理 `cats: [String: CatSprite]` 字典，系统猫需要在不污染会话猫字典的前提下新增。

**明确约束**：
- 不引入 Sparkle 等外部框架
- 保持 brew upgrade 升级路径
- 遵循现有 EventBus 发布/订阅模式
- About 页面 UI 遵循 SettingsTheme token 体系
- 系统猫复用 CatSprite 组件，普通猫外观

## 候选方案与权衡

### 方案 A：UpdateChecker 增强 + SystemCatManager（✅ 选定）

**架构**：

```
UpdateChecker  ──updateAvailable──→  SystemCatManager  ──→  BuddyScene（系统猫 CatSprite）
       │                                      │
       │                              点击系统猫 → 打开设置 → 记录 dismissedVersion
       │
       └──upgradeProgress──→  AboutSettingsViewController（进度条 + 阶段文字）
```

**改动文件**：

| 文件 | 改动 |
|------|------|
| `UpdateChecker.swift` | + `dismissedVersion` UserDefaults 持久化（`UserDefaults.dismissedUpdateVersion`）；+ `upgradeProgress` PassthroughSubject；+ `startUpgrade()` 改为流式发布阶段（checking → downloading → installing → done/failed）；+ `shouldShowSystemCat()` 方法（版本 > 当前 且 未被 dismiss） |
| `SystemCatManager.swift`（新） | 管理单只系统猫的完整生命周期：`showIfNeeded()` / `hide()` / `handleClick()`；监听 `EventBus.updateAvailable`；点击回调 → `UpdateChecker.shared.dismissVersion()` + 打开设置 → 关于 |
| `BuddyScene.swift` | + `systemCat: CatSprite?`；`simulateClick` 修复：先检查是否为系统猫（update badge 改为系统猫专用徽章）；`addCat` 不再为普通猫加更新徽章 |
| `AppDelegate.swift` | **修复 onClick bug**：改为调用 `scene?.simulateClick(sessionId:)`，删除重复的 ack/removePersistent 逻辑；+ `openSettingsToAbout()` 方法 |
| `AboutSettingsViewController.swift` | + `NSProgressIndicator`（indeterminate）+ 阶段状态 `NSTextField`（"正在检查更新..."→"正在下载..."→"安装完成 ✓"）+ 「检查更新」按钮 + 「立即升级」按钮；监听 `UpdateChecker.shared.upgradeProgress` |
| `CatSprite.swift` | `updateBadgeNode` 保留但仅系统猫使用；移除 `startUpgradeAnimation()`（或保留给系统猫） |
| `LabelComponent.swift` | 更新徽章逻辑不变，仅系统猫调用 |
| `SettingsSplitViewController.swift` | + `selectSection(.about)` 公开方法，支持外部跳转到关于页 |

**优势**：
- 职责清晰：SystemCatManager 管猫生命周期，UpdateChecker 管 API + brew，About 页面只管 UI
- 复用 CatSprite 组件，系统猫有完整动画
- 遵循现有 EventBus 模式，最小化对现有代码的侵入
- 后续系统通知（skin 更新等）可复用 SystemCatManager
- 同时修复了 onClick bug

**劣势**：
- 新增 SystemCatManager 类，增加一个抽象层
- 系统猫使用完整 CatSprite（含状态机），对静态展示来说稍重

### 方案 B：最简直驱（无 Manager）

**架构**：UpdateChecker 直接控制场景中的轻量 `SKSpriteNode`，不引入 SystemCatManager。

**改动文件**：

| 文件 | 改动 |
|------|------|
| `UpdateChecker.swift` | 同方案 A（去重 + 进度发布） |
| `BuddyScene.swift` | 直接管理一个简单 `SKSpriteNode`（非 CatSprite），监听 `updateAvailable` 显示/隐藏 |
| `AppDelegate.swift` | 修复 onClick bug |
| `AboutSettingsViewController.swift` | 同方案 A |

**优势**：最快落地，无新类；系统通知节点轻量

**劣势**：
- UpdateChecker + BuddyScene 耦合加深
- 纯静态节点没有像素猫动画，视觉效果单调
- 未来系统通知需重复实现

## 选择与理由

**选定方案：A（UpdateChecker 增强 + SystemCatManager）**

选择理由：
- 用户明确选择系统猫方案（Q2），方案 A 是此选择的自然架构表达
- 修复 onClick bug 内聚在此方案中，一举两得
- 后续系统通知可复用 SystemCatManager，投资合理
- 复用 CatSprite 保持像素猫视觉一致性

被排除方案：
- 方案 B：扩展性差，静态节点缺乏猫咪动画，用户选择系统猫隐含期望猫咪外观
- 方案 C（菜单栏通知）：用户在 Q4 明确排除

## 待主 SKILL 接力的设计决策

以下决策已由用户确认，主 skill 写设计文档时直接纳入：

1. **进度展示**：分阶段状态文字（检查中 → 下载中 → 安装中 → 完成/失败）+ 不确定 NSProgressIndicator（旋转跑马灯风格），位于关于页版本号下方

2. **系统猫**：复用普通 CatSprite 外观（随机皮肤），检测到新版本时出现在场景固定位置（最右侧床区域旁），点击后消失。带绿色更新徽章（复用现有 LabelComponent 更新徽章）

3. **去重策略**：`UpdateChecker` 维护 `UserDefaults.dismissedUpdateVersion: String`。点击系统猫 → 打开设置关于页 → 立即写入新版本号。同版本永久不再提示，只有更高版本才重新触发系统猫

4. **点击流程**：系统猫点击 → `BuddyScene.simulateClick` 识别为系统猫 → 记录 dismissedVersion → 移除系统猫 → 打开设置窗口 > 关于分类 → 关于页自动触发 `checkForUpdates()`

5. **关于页 UI**：在版本号下方、反馈按钮上方，新增更新区域（NSProgressIndicator + 状态标签 + 「检查更新」/「立即升级」按钮），升级过程中按钮禁用防止重复点击

6. **Bug 修复**：`AppDelegate.onClick` 改为调用 `scene?.simulateClick(sessionId:)`，删除其中手动重复的 `acknowledgePermission`/`removePersistentBadge` 逻辑

7. **brew 进度解析**：`Process` stdout 流式读取，按关键词匹配阶段（`==>` → downloading, `Pouring` → installing），其余行作为日志缓存；任意阶段失败 → 状态变为 failed，展示最后 3 行 stderr
