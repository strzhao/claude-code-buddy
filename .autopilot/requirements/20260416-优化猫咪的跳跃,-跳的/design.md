# 设计文档：猫咪跳跃物理优化

## 技术决策
使用抛物线轨迹方程 `y(t) = y₀ + v₀y·t - 0.5·g·t²` 在 SKAction.customAction 中模拟物理跳跃。
该方程与物理引擎的匀变速积分在数学上等价，但避免了内置物理引擎的三个问题：
场景重力 -9.8 太弱需提高（波及食物系统）、地面碰撞体在 y=0 与猫位置 y=48 不匹配、轨迹不可控。

## 核心参数
- 跳跃重力: 800 px/s²
- 初速度范围: v₀y = 140-200 px/s（峰值 12-25px，适配 80px 窗口高度）
- 水平速度范围: v₀x = 280-500 px/s
- 蓄力时间: 0.08-0.20s 随机

## 视觉增强
1. Crouch: scaleY → 0.65, 0.08-0.20s
2. Launch: scaleY → 1.3, 0.06s
3. Air stretch: 根据垂直速度比例拉伸 scaleY/squeeze scaleX
4. Landing squash: scaleX → 1.3, scaleY → 0.6, 恢复 0.15s
5. 灰尘粒子: 6 个 inline SKSpriteNode, 0.4s 淡出
