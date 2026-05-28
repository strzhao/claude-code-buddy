# Swift Optional 用 `?? "default"` 序列化到 hash 时 nil 与"default"碰撞，需结构性 tag 区分

<!-- tags: swift, optional, hash, sha256, serialization, collision, trustkey, structural-tag, security, red-team, plan-reviewer-miss -->

**Scenario**: task 005 给 launcher trust 算法加 prompt mode 支持。设计文档的 trustKey 公式：

```swift
case .prompt(let cfg):
    let modelStr = cfg.model ?? "default"      // ⚠️ 看起来合理
    let combined = "\(cfg.systemPrompt)\n\(cfg.maxIterations)\n\(modelStr)"
    return "prompt:" + SHA256.hash(data: Data(combined.utf8)).hexString
```

意图是"`model: nil` 时用 default 占位计算 hash"，但**红队抓到 bug**：
- manifest A：`model: nil`
- manifest B：`model: "default"`
- 两者 `?? "default"` 后都得到字符串 `"default"`
- → 完全相同的 hash → 完全相同的 trustKey
- 违反设计意图（trust 应区分二者，防误用）

plan-reviewer 没抓到（视为合理 placeholder）；红队场景 6 (`test_06_promptModelNilVsDefault_producesDifferentTrustKeys`) 直接断言 nil/"default" 必须不同 → 第一次跑测试就红灯，揭露真 bug。

**Lesson**: 把 Optional 序列化到 hash/缓存/trust 等场景时，**任何 `?? "fallback_string"` 模式**都会让 `nil` 与 `"fallback_string"` 碰撞。**结构性 tag** 是标准解法：

```swift
// ❌ 错：?? 让 nil 与 "default" 碰撞
let modelStr = model ?? "default"

// ✅ 对：结构性 tag 区分 Optional 状态
let modelPart = model.map { "1:\($0)" } ?? "0"
// nil → "0"（无值标记）
// 非 nil → "1:value"（有值标记 + 内容）
// 即使用户 model="0"，编码为 "1:0"，不与 nil 的 "0" 碰撞
```

通用规则：
- tag `0` = absent, tag `1` + 分隔符 + value = present
- 分隔符（如 `:`）让 value 内容无法逃逸成 absent tag
- 同模式适用于 JSON encode 时 Optional 不能用 `?? null` 或 `?? ""` 当默认值（碰撞）

**应用场景**：
- TrustKey / cacheKey / signatureKey 用 hash 计算时
- DB 查询字符串拼接（防 key 冲突）
- 配置 ETag 计算（区分 absent 配置 vs default 配置）

**Evidence**: task 005 红队 `test_06_promptModelNilVsDefault_producesDifferentTrustKeys` 第一次跑测试就 fail，证明设计 `model ?? "default"` 与 `manifest.model="default"` 碰撞。修正为 `model.map { "1:\($0)" } ?? "0"` 后红队 test_06 PASS + test_10b（独立算法一致性）也 PASS。

**反面**：plan-reviewer 6 维度都没抓到此 bug（视为"合理 placeholder"，未实际推演 nil vs 字符串碰撞场景）→ 教训：**plan-reviewer 应特别关注 Optional 进 hash 的场景**，要求 reviewer 显式推演"如果 user 提供与 fallback 字符串相同的值会如何"。

**关联**：
- 与 Anti-Overfitting：通用 Swift/Optional 模式，不限 launcher 场景
- 与 task 002 patterns（Codable 处理）：Optional 字段序列化的另一种陷阱
- 与 RFC 6962（Certificate Transparency 用 0x00/0x01 域分离防 hash 碰撞）同思路
