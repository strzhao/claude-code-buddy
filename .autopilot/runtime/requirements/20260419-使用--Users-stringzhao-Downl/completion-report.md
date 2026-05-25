# Satyr 皮肤包完成报告

## 目标
从 SATYR 精灵图（320x352, 32x32 格子）切片制作皮肤包并上传到皮肤商店。

## 产出物
- **Scripts/pack-satyr-skin.py** — Python 一键切片脚本
- **satyr-skin.zip** — 60KB 皮肤包（已上传）
- **皮肤商店状态**: pending（需 admin 审核）

## 动画映射
| 行 | 精灵内容 | Buddy 动画 | 帧数 |
|----|---------|-----------|------|
| 0 | 站立呼吸 | idle-a | 6 |
| 1 | 行走 | walk-a | 8 |
| 2 | 挥砍攻击 | paw | 4 |
| 3 | 重击攻击 | walk-b | 7 |
| 4 | 闪避/蹲伏 | clean | 6 |
| 5 | 受击反应 | scared | 6 |
| 6 | 死亡消散(前4帧) | jump | 4 |
| 8 | 低姿势休息 | sleep | 6 |
| 9 | 物体交互 | idle-b | 10 |

**总计**: 57 帧动画 + 16 menubar 帧 + bed/boundary/food/preview 占位

## 知识沉淀
- Pattern: 精灵图 alpha 帧检测被粒子/特效残留误导 → .autopilot/patterns.md (48f983f)

## Commit
- `1210785` chore(scripts): 新增 SATYR 精灵图切片脚本
- `48f983f` docs(knowledge): 精灵图 alpha 帧检测被粒子残留误导（主仓库）
