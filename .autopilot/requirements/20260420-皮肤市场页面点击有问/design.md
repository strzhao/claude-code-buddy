## 设计文档

**根因**：`SkinGalleryViewController.collectionView(_:itemForRepresentedObjectAt:)` 配置远程皮肤卡片时从未给 `cardItem.onDownload` 赋值。

- Download 按钮居中覆盖预览图区域，用户点击远程皮肤卡片大概率命中按钮
- `handleClickAt` 检测到 NSButton hit 后 return early，让按钮自行处理
- 按钮触发 `handleDownload()` → `onDownload?()` → nil → 无反应
- 造成"双击才有反应"的感觉（第一次点按钮无效，第二次点到空白区域才触发下载）

**修复**：在远程皮肤配置分支中添加 `cardItem.onDownload` 闭包赋值
