# 两阶段迁移幂等 + crash safe：每 Phase 入口重读 state，不复用前 Phase 变量

<!-- tags: migration, idempotency, crash-safe, state-machine, marketplace-manager, plan-reviewer-blocker, swift, filesystem, trust-store, multi-phase -->

**Scenario**: task 003 MarketplaceManager 需要把老用户 `~/.buddy/launcher-plugins/builtin-translate/` + `launcher-trust.json` 中 `pluginName="builtin-translate"` 迁移到新 name `"translate"`。**老用户体验必须无感**：trustKey 不变（不重弹 NSAlert），数据零丢失。

第一版设计（plan-reviewer B1 抓出问题）：

```swift
private func migrateOne(oldName: String, newName: String) throws {
    let oldDir = pluginsDir.appending(path: oldName)
    let newDir = pluginsDir.appending(path: newName)
    let oldDirExists = FileManager.default.fileExists(atPath: oldDir.path)  // ❌ 顶部一次性读
    let newDirExists = FileManager.default.fileExists(atPath: newDir.path)
    
    // Phase 1: 写新目录
    if oldDirExists && !newDirExists { try FileManager.default.copyItem(...) }
    
    // Phase 1.5: 写新 trust
    let records = trustStore.list()
    let hasOld = records.contains { $0.pluginName == oldName }      // ❌ 用 Phase 1.5 之前快照
    let hasNew = records.contains { $0.pluginName == newName }
    if hasOld && !hasNew { try trustStore.addRecord(...) }
    
    // Phase 2: 删旧
    if FileManager.default.fileExists(atPath: newDir.path) && oldDirExists {
        try FileManager.default.removeItem(at: oldDir)   // ❌ oldDirExists 是 Phase 1 之前的快照
    }
    if hasOld { try trustStore.remove(pluginName: oldName) }   // ❌ hasOld 是 Phase 1.5 之前快照
}
```

**plan-reviewer 抓的 crash 路径**：
- crash 在 Phase 1 之后 / Phase 1.5 之前 → 再次启动时 `oldDirExists` 仍读为 true（仍存在），`newDirExists` 也 true，Phase 1 跳过；但 Phase 1.5 的 `hasOld/hasNew` 仍是当前快照，OK
- 实际更危险：**复用变量会让逻辑无法验证**。每 Phase 用前 Phase 快照，crash 中间发生时变量含义模糊

**Lesson**: 多阶段迁移必须每 Phase 入口**重新 read state，绝不复用前 Phase 变量**。每 Phase 独立判断"是否需要做"，这样 crash 后再次进入会自动走到正确的下一步。

```swift
private func migrateOne(oldName: String, newName: String) throws {
    let oldDir = pluginsDir.appending(path: oldName)
    let newDir = pluginsDir.appending(path: newName)
    
    // ============ Phase 1: 写新目录 ============
    // 入口重读 state
    let phase1OldExists = FileManager.default.fileExists(atPath: oldDir.path)
    let phase1NewExists = FileManager.default.fileExists(atPath: newDir.path)
    if phase1OldExists && !phase1NewExists {
        try FileManager.default.copyItem(at: oldDir, to: newDir)
        try renamePluginJSON(at: newDir.appending(path: "plugin.json"), to: newName)
    }
    
    // ============ Phase 1.5: 写新 trust ============
    // 入口重读 state（不复用 phase1 变量）
    let phase15Records = (try? trustStore.list()) ?? []
    let phase15HasOld = phase15Records.contains { $0.pluginName == oldName }
    let phase15HasNew = phase15Records.contains { $0.pluginName == newName }
    if phase15HasOld && !phase15HasNew {
        if let oldRecord = phase15Records.first(where: { $0.pluginName == oldName }) {
            try trustStore.addRecord(TrustRecord(
                trustKey: oldRecord.trustKey,    // 关键：保留原 trustKey 不变
                pluginName: newName,
                approvedAt: oldRecord.approvedAt
            ))
        }
    }
    
    // ============ Phase 2: 删旧 ============
    // 入口重读 state（不复用 phase1/phase15 变量）
    let phase2OldDirExists = FileManager.default.fileExists(atPath: oldDir.path)
    let phase2NewDirExists = FileManager.default.fileExists(atPath: newDir.path)
    if phase2NewDirExists && phase2OldDirExists {
        try FileManager.default.removeItem(at: oldDir)
    }
    let phase2Records = (try? trustStore.list()) ?? []
    let phase2HasNew = phase2Records.contains { $0.pluginName == newName }
    let phase2HasOld = phase2Records.contains { $0.pluginName == oldName }
    if phase2HasNew && phase2HasOld {
        try trustStore.remove(pluginName: oldName)
    }
}
```

**幂等性矩阵**（验证 crash 在任意 Phase 之后再次启动行为正确）：

| 状态 | Phase 1 | Phase 1.5 | Phase 2 |
|------|---------|-----------|---------|
| 首次（旧 dir+trust 在，新都不在）| 写新 dir | 写新 trust | 删旧 |
| crash 在 Phase 1 之后 | skip（new dir 已存在）| 写新 trust | 删旧 |
| crash 在 Phase 1.5 之后 | skip | skip（new trust 已存在）| 删旧 |
| crash 在 Phase 2 中（旧 dir 已删，旧 trust 还在）| skip | skip | 仅删 trust |
| 已完成 | skip | skip | skip |

**核心铁律**：

1. **每 Phase 独立 read state**：FileManager.fileExists 重读、trustStore.list 重读
2. **不复用前 Phase 快照变量**：变量命名带 `phase1` / `phase15` / `phase2` 前缀强调
3. **每 Phase 自包含完成条件**：`if state 还未到位 { do action }`，否则 skip
4. **顺序 = 副作用方向**：先创建（Phase 1/1.5），再删除（Phase 2）。crash 在中间留下"双份"状态，下次启动会被正确清理
5. **关键不变量必须显式**：本例中 trustKey 不变是核心承诺（prompt-mode trustKey = SHA256(systemPrompt + maxIter + modelPart) 不依赖 pluginName）

**Evidence**: task 003 plan-reviewer 第 1 轮 B1 抓出此问题；第 2 轮 PASS。红队 AT01-AT05 覆盖 5 个 Phase 路径（首次 / Phase 1 后 crash / Phase 1.5 后 crash / 已完成 / trustKey 不变验证），全 PASS。Tier 1.5 S2 真 app boot 验证 `trustKey "prompt:abc123def4567890"` 迁移前后字面相等，旧 record 删 + 新 record 加。

**关联**：
- 与"原子性 vs 幂等性"：原子性（事务）需要 DB 支持；幂等性（重试安全）只需"每步独立验证状态 + 状态正确才执行"
- 与 macOS app 重启迁移场景：因为 app 进程可能在任何时刻被用户 kill / Mac sleep / app crash，所有持久化变更路径都应考虑幂等性
- 类似教训：避免"flag-based" 状态机（如 `migrationCompleted: Bool`），改为"shape-based" 状态机（"如果新 dir 已在且旧 dir 不在 → 已完成"）。Flag 易丢失/绕过；shape 直接反映真实状态
