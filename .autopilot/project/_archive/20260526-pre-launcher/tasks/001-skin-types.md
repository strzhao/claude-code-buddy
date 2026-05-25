---
id: "001-skin-types"
depends_on: []
---

# 001: SkinPackManifest + SkinPack 核心类型

## 目标
定义皮肤包系统的基础数据模型，所有后续任务依赖此接口。

## 架构上下文
- 新目录: `Sources/ClaudeCodeBuddy/Skin/`
- 参考设计文档中的 `SkinPackManifest` 和 `SkinPack` 结构

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Skin/SkinPackManifest.swift` — Codable + Equatable，含嵌套 MenuBarConfig
- `Sources/ClaudeCodeBuddy/Skin/SkinPack.swift` — SkinSource enum (builtIn/local) + url() 资源解析方法
- `Tests/BuddyCoreTests/SkinPackTests.swift` — 单元测试

## 输入/输出契约

### 输出
- `SkinPackManifest`: 所有字段 let，Codable 可从 JSON 反序列化
- `SkinPack.url(forResource:withExtension:subdirectory:) -> URL?`: builtIn 走 Bundle.url() 带 "Assets/" 前缀，local 走 FileManager 拼接

### 关键细节
- `canvasSize` 用 `[CGFloat]` 而非 CGSize（JSON 友好）
- `SkinPack` 的 `Equatable` 基于 `manifest.id`
- builtIn source 的 subdirectory 自动加 "Assets/" 前缀

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter SkinPackTests` 全部通过
- [ ] Manifest JSON 序列化/反序列化 round-trip 测试
- [ ] builtIn 和 local 两种 SkinSource 的 url() 解析测试
- [ ] 缺失资源返回 nil 测试
