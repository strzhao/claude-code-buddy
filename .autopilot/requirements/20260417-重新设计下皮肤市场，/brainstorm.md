# Brainstorm: 重新设计皮肤市场

## 需求分析

用户反馈当前皮肤市场存在以下问题：
1. **窗口太小** — 当前 320×400 NSPanel，浏览体验差
2. **UI 没对齐** — 布局存在对齐问题
3. **扩展性** — 后续会持续增加皮肤包，需要更好的浏览体验
4. **音效缺失** — 皮肤包需要支持自定义音效

## 现有架构

### 皮肤系统（已在 main 分支实现）
- `SkinPackManifest` — 皮肤包元数据（id, name, author, sprites, animations, beds, food, menuBar）
- `SkinPack` — 皮肤包实例（manifest + source: builtIn/local）
- `SkinPackManager` — 单例管理器（选择/加载/Combine 发布）
- `SkinPackStore` — 远程商店（catalog 获取、下载、解压、校验）
- `SkinGalleryViewController` — 设置窗口（300×480 容器，垂直列表）
- `SkinGalleryItemView` — 80px 高卡片（60×60 预览 + 名称/作者）
- `SettingsWindowController` — 320×400 NSPanel

### 音效参考源（task-notifier 插件）
- 两个音效文件：`freesound_community-goodresult-82807.mp3`（完成音）、`confirm.mp3`（权限请求音）
- 两个触发事件：`Stop`（任务完成）、`PermissionRequest`（权限请求）
- 播放方式：`afplay -v 0.3` 后台播放
- App 当前无任何音频基础设施

## Q&A 结论

| 问题 | 决策 |
|------|------|
| 窗口布局 | **网格布局**：更大窗口（~600×500），2-3 列网格，大预览图 |
| 音效集成 | **App 内置播放**：通过 AVFoundation 播放，音效文件内嵌皮肤包 |
| 音效范围 | **保持一致**：仅 Stop + PermissionRequest 两个场景，与 task-notifier 保持一致 |
| 已安装 vs 商店 | **混合展示**：所有皮肤混在同一网格，已安装显示 ✓，未安装显示下载按钮 |
| 音效冲突 | **加开关**：Settings 里添加音效开关（默认开），用户自行管理与 task-notifier 的共存 |
