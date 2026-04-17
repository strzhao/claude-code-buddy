# 设计文档：重新设计皮肤市场

## 目标
重新设计皮肤市场 UI（网格布局 + 更大窗口）+ 给皮肤包增加音效支持

## 技术方案
1. **Manifest 音效扩展** — SkinPackManifest 新增 Optional `sounds: SoundConfig?`，SoundConfig 含 taskComplete/permissionRequest/directory 全 Optional 字段
2. **SoundManager** — 单例，AVAudioPlayer 播放，订阅 EventBus.stateChanged（.receive(on: RunLoop.main)），过滤 taskComplete/permissionRequest，音量 0.3，UserDefaults 开关
3. **音效文件** — 从 task-notifier 复制 complete.mp3 + confirm.mp3 到 Assets/Sounds/
4. **UI 重设计** — SettingsWindow 600×500，NSCollectionView 3 列网格，单 section 混合展示，SkinCardItem 替换 SkinGalleryItemView，底部音效开关
