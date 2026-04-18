### 目标
点击消除持久徽章 + 增大猫屋间距防止标签重叠

### Fix 1: 点击消除持久徽章
- BuddyScene 新增 removePersistentBadge(for:)
- AppDelegate.onClick 闭包中调用

### Fix 2: 增大猫屋间距
- slotSpacing 从 -56 → -100（-80 仍重叠）
