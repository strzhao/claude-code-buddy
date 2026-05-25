# 设计文档: 支持 App 升级

## 目标
启动时 + 24h 间隔检查 GitHub Releases API，发现新版本后在猫咪上方显示绿色升级气泡（↑），用户点击后自动执行 `brew upgrade claude-code-buddy` 并重启 app。

## 技术方案
- **数据流**: UpdateChecker → EventBus.updateAvailable → BuddyScene → CatSprite 气泡
- **升级动画**: CatSprite.startUpgradeAnimation() 使用 paw 帧 repeatForever（不使用 CatEatingState，因为需要 FoodSprite）
- **Homebrew 检测**: /opt/homebrew/bin/brew + /usr/local/bin/brew
- **版本比较**: Bundle.main CFBundleShortVersionString vs GitHub tag_name（strip v 前缀）
- **回退**: 无 brew → 浏览器打开 GitHub Releases
- **防重复**: isUpgrading 标志防止多次触发
- **启动延迟**: 10s 后首次检查

## 文件影响范围
| 文件 | 操作 | 说明 |
|------|------|------|
| Update/UpdateChecker.swift | 新增 | 版本检查 + brew 执行 + 重启 |
| Event/BuddyEvent.swift | 修改 | 添加 UpdateAvailableEvent |
| Event/EventBus.swift | 修改 | 添加 updateAvailable publisher |
| Entity/Components/LabelComponent.swift | 修改 | 添加升级气泡创建/移除 |
| Entity/Cat/CatSprite.swift | 修改 | 添加升级动画 + 气泡属性 |
| Entity/Cat/CatConstants.swift | 修改 | 添加气泡常量 |
| Scene/BuddyScene.swift | 修改 | 订阅事件 + 气泡管理 + 点击处理 |
| App/AppDelegate.swift | 修改 | 初始化 UpdateChecker |
| Scene/SceneControlling.swift | 修改 | 添加 hasUpdateBadge |
