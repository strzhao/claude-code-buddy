# CatPersonality 随机生成不持久化

<!-- tags: personality, random, persistence -->

**决策**: 每只猫在 init 时通过 `CatPersonality.random()` 随机生成性格参数，不持久化到磁盘。每次 app 重启所有猫获得新性格。

**否决**: 将性格参数写入 UserDefaults 或文件持久化，重启后恢复。

**理由**:
- 持久化增加复杂度（需关联 session_id、处理清理），收益仅为"猫的性格跨重启一致"
- 桌面宠物的乐趣之一是不可预测性，每次随机反而增加趣味
- 测试用 `CatPersonality.balanced` 固定值，不受随机影响

**影响文件**: CatPersonality.swift(新建), CatSprite.swift

**约束**: 如果未来需要"记住猫的性格"，添加 `Codable` 一行即可序列化。当前不预留序列化接口。
