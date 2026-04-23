# Brainstorm: 支持 app 升级

## Q&A 记录

### Q1: 升级模式？
**A**: 版本检查 + 通知跳转（非 Sparkle 自动更新）

### Q2: 检查时机？
**A**: 启动时检查一次，24h 间隔后再检查（UserDefaults 记录上次检查时间）

### Q3: 通知方式？
**A**: 猫咪气泡通知（复用现有 tooltip/label 风格）

### Q4: 版本数据源？
**A**: GitHub Releases API (`/repos/strzhao/claude-code-buddy/releases/latest`)

### Q5: 点击行为？
**A**: 直接调用 `brew upgrade claude-code-buddy`，猫咪展示升级过程

### Q6: 升级流程？
**A**: 自动流程 — 点击 → brew upgrade → 猫咪 eating 状态 → 完成后自动重启 app

### Q7: 猫咪升级视觉？
**A**: 复用 eating 状态（吃鱼动画 = 升级中）

### Q8: 架构方案？
**A**: 事件驱动架构 — UpdateChecker → EventBus → CatSprite 气泡 → UpgradeManager → brew+重启

## 选定架构

```
UpdateChecker (GitHub API)
    ↓ EventBus(.updateAvailable)
SessionManager → 转发给活跃猫
    ↓
CatSprite → 显示升级气泡
    ↓ 用户点击
UpgradeManager → brew upgrade
    ↓ 监听进度
CatSprite → eating 状态
    ↓ 完成
AppRestart → open + terminate
```

**新增文件**:
- UpdateChecker.swift (GitHub API 版本检查)
- UpgradeManager.swift (brew upgrade + app 重启)
- BuddyEvent+Update.swift (升级相关事件)

**修改文件**:
- CatSprite.swift (气泡 + 点击处理)
- SessionManager.swift (事件转发)
- AppDelegate.swift (初始化检查器)
