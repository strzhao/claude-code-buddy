# 中文标签间距需比拉丁字符预估值大 ~2 倍

<!-- tags: spritekit, labels, spacing, cjk, font-size -->
**Scenario**: 猫屋 bed slot 间距 -56px，改为 -80px 后中文标签仍重叠，最终需 -100px
**Lesson**: 12pt 中文字符宽度约 12-14px/字，比拉丁字符（~7px/字）宽近 2 倍。估算中文标签所需间距时，不能按拉丁字符的 charWidth 预估——应以实际中文标签长度（字数 × 13px + padding）为基准，并留 20% 余量。对于 4-6 个中文字符的标签，100px 间距是安全下限。
**Evidence**: slotSpacing -56 → -80 用户反馈仍重叠 → -100 通过验收
