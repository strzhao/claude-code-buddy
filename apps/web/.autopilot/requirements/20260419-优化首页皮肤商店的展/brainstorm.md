# Brainstorm: 优化首页皮肤商店展示

## 目标

优化首页皮肤商店的展示：

1. 默认猫咪皮肤要展示出来
2. Dog 皮肤封面不对，需修复
3. Hover 到皮肤上要有动画展示素材

## 关键发现

### 代码结构

- 首页 `src/app/page.tsx` → `SkinsSection` → `SkinCard`
- `SkinsSection` 是 async server component，直接调用 `listSkinsByStatus("approved")`
- `SkinCard` 极简：preview 图 + 名称 + 作者，无 hover 效果
- 猫咪帧图在 `/public/sprites/cats/`（9 组动画，共 53 帧），仅供 hero PixiJS 用
- 远程皮肤素材在 Blob zip 中，无法直接访问单帧

### 现有动画

- `pixel-entrance`: 入场动画（opacity + translateY）
- `pixel-shimmer`: 闪光背景
- `ScrollReveal` 组件 + IntersectionObserver

## 用户决策

### Q1: 默认猫咪皮肤展示方式

**选择**: 前端硬编码虚拟卡片

- 在 SkinsSection 中手动插入一个"默认猫咪"卡片
- 使用 /public/sprites/cats/ 的素材作为预览和动画
- 不写入 Redis，仅前端展示

### Q2: Hover 动画方案

**选择**: 本地皮肤帧动画 + 远程皮肤静态效果

- 猫咪皮肤：hover 时播放帧动画（如 idle-a 的 8 帧循环）
- 远程皮肤（如 dog）：hover 时展示放大 + 像素风发光/阴影增强
- 两种模式统一卡片结构，通过 props 区分行为

### Q3: Dog 皮肤封面修复

**选择**: 调查并修复 Redis 数据

- 通过 API/脚本查询 Redis 中 dog 皮肤的实际 preview_blob_url
- 确认是 URL 错误还是图片内容错误
- 修复 Redis 数据或重新提取 preview
