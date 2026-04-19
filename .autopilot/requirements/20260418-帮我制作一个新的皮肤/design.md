## 设计文档

见 plan 文件: /Users/stringzhao/.claude/plans/encapsulated-sniffing-blossom.md

核心设计：manifest.json 新增可选 `variants: [SkinVariant]?` 数组，每个变体有独立的 `sprite_prefix`，共享其他配置。默认随机选色。

