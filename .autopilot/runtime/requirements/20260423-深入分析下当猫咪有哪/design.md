# 设计文档: 猫咪自然度全量优化

## 方案
A: 过渡引擎 + 性格系统

## 新增基础设施
1. **EasingCurves** — 8 种猫咪专用缓动曲线 (catWalkStart/Stop, catTurn, catJump, catLand, catBreathe, catStartle, catExcited)
2. **CatPersonality** — 4 维性格参数 (activity/curiosity/timidness/playfulness, 0.3-1.0 随机生成)
3. **AnimationTransitionManager** — 过渡协调器 (smoothTurn, easeOutHandoff, anticipate, followThrough, startEnhancedBreathing, playWeatherReaction)

## 修改文件
- CatSprite.swift: personality 属性 + smoothTurn + 天气视觉反应 + 性格影响兴奋跳跃
- MovementComponent.swift: 性格速度系数
- JumpComponent.swift: 性格跳跃速度 + 缓动曲线
- InteractionComponent.swift: startle anticipation + 性格受惊距离
- DragComponent.swift: lerp 重量感 + 缓动着陆
- AnimationComponent.swift: 性格增强呼吸
- CatIdleState.swift: 性格修正 idle 权重

## 解决的 10 类问题
1. 状态转换断裂 → easeOutHandoff
2. 方向瞬间翻转 → smoothTurn
3. 运动无加减速 → EasingCurves + 性格速度
4. 缺乏预期动作 → startle anticipation + catJump
5. 缺乏跟随动作 → catLand + 性格影响保持时长
6. 行为过于规律 → 性格修正 idle 权重
7. 交互反应机械 → 性格影响跳跃/受惊
8. 环境感知薄弱 → 天气视觉反应
9. 拖拽缺乏质感 → lerp 重量感
10. 呼吸微动太弱 → 性格影响呼吸振幅
