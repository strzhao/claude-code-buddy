# 设计文档：App Icon Brew 安装缺失修复

## 根因
v0.12.0 发布时 release.yml 缺少 `cp AppIcon.icns` 步骤。已在 b98db31 修复但未发版。

## 技术方案
1. 统一 bundle.sh 和 release.yml 防御姿态 — 移除 `if [ -f ]` 保护
2. release.yml 添加 bundle 完整性验证步骤

## 文件影响
| 文件 | 操作 | 说明 |
|------|------|------|
| Scripts/bundle.sh | 修改 | 移除 icon cp 的 if 保护 |
| .github/workflows/release.yml | 修改 | 添加 Verify bundle integrity step |
