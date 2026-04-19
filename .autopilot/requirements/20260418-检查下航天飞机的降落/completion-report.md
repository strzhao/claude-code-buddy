# 完成报告 — 修复航天飞机降落时 ET 视觉遮挡

**需求**: 检查下航天飞机的降落过程，降落的时候中间的外储罐被遮挡了一半的问题
**状态**: done
**日期**: 2026-04-18

## 变更概览
| 文件 | 操作 | 说明 |
|---|---|---|
| `Scripts/generate-rocket-sprites-v2.swift` | 修改 | landing_a yOff 6→1、landing_b yOff 3→0，+注释 |
| `Sources/.../rocket_shuttle_landing_a.png` | 重生成 | ET 鼻锥完整可见 |
| `Sources/.../rocket_shuttle_landing_b.png` | 重生成 | ET 鼻锥完整可见 |

## 根因
shuttle ET 最高像素 y = `46 + yOff`，画布高度 48。原 landing_a（yOff=6）裁切 ET 鼻锥 5 行，视觉上"ET 只剩一小段"。

## 关键决策
1. **最小改动**: 改 yOff 数值而非重新设计 shuttle sprite 布局
2. **Scope 严守**: 仅动 landing_a/b；liftoff 和 cruise 同根因但不在需求范围内
3. **保留场景动画**: 场景级 `containerNode.moveTo` 仍承担下降观感，精灵内部 yOff 只是辅助

## 验证
- `make build` ✅
- `make test` ✅ 416/0
- 视觉 diff（PNG Read）✅ ET 完整

## 沉淀
新增 pattern：`[2026-04-18] 精灵帧内 yOff 偏移会被画布顶部静默裁切` → `.autopilot/patterns.md`

未来调整任何 rocket sprite 的 yOff 时，先算 `max_body_y + yOff ≤ canvas_height - 1`，避免无提示裁切。
