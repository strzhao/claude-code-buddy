# 完成报告：皮肤包颜色变体系统 + Pixel Dog 皮肤

## 提交
- **commit**: `b38cd76` on branch `worktree-skin`
- **版本**: 0.11.0 → 0.12.0
- **文件**: 16 files, +575/-49

## 交付物

### 桌面端功能
1. **颜色变体系统** — manifest `variants` 字段支持多颜色变体，用户选择皮肤后可选颜色或随机
2. **精灵朝向声明** — `sprite_faces_right` 字段让第三方皮肤声明朝向，app 自动适配
3. **异步纹理加载** — 切换皮肤不再阻塞 UI
4. **Settings 面板点击修复** — 绕过 NSCollectionView 选择机制解决 LSUIElement 兼容性

### Web 商店
5. **类型更新** — `SkinVariant` + `variant_count` 字段
6. **验证更新** — 可选 variants 校验
7. **Blob token 修复** — Production 环境 token 格式错误已修复

### 皮肤包
8. **Pixel Dog** — 12 颜色变体，756 帧精灵，已上传到 buddy.stringzhao.life（status: pending → approved）

### 工具
9. **slice-dog-sprites.swift** — 从 sprite sheet 切出多变体帧
10. **CLI --facing 参数** — 帮助第三方作者声明精灵朝向

## 关键架构决策
- 颜色变体作为 manifest 内部数组，而非独立皮肤包
- Settings 面板通过 Panel.sendEvent 直接分发点击，绕过 NSCollectionView 选择（LSUIElement 限制）

## 已知限制
- 变体选择 UI（NSSegmentedControl）在 12 个变体时可能溢出卡片宽度
- Web 商店的 variants 验证代码尚未部署到 production（本地改好）
