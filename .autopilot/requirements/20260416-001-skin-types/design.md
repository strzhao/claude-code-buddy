# 001-skin-types 设计文档

- **目标**: 创建 SkinPackManifest（Codable 元数据）和 SkinPack（manifest + 资源解析）两个核心类型
- **技术方案**: 遵循项目 Codable 模式（显式 CodingKeys、snake_case JSON 映射）
- **文件**: SkinPackManifest.swift + SkinPack.swift (新建 Skin/ 目录) + SkinPackTests.swift
- **接口**: SkinPack.url(forResource:withExtension:subdirectory:) — builtIn 补 "Assets/" 前缀，local 走 FileManager
