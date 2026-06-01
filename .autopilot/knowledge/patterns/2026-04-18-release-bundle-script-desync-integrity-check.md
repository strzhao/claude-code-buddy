# release.yml 与 bundle.sh 打包步骤不同步导致 CI 产物缺资源

<!-- tags: ci, release, packaging, bundle, icon, if-guard, integrity-check -->
**Scenario**: 本地 `make bundle`（调用 Scripts/bundle.sh）打包的 .app 有 icon，但 GitHub CI release.yml 打包的 .app 缺少 icon
**Lesson**: 项目有两条独立的 .app bundle 组装路径：`Scripts/bundle.sh`（本地）和 `.github/workflows/release.yml`（CI）。新增 bundle 内容（如资源文件、新的可执行文件）时，必须在两处同时添加 cp 步骤。排查"本地有 CI 没有"问题时，优先 diff 这两个文件。同类陷阱：plugin 缓存与源码不同步（见上方条目）。
**防御措施（2026-04-19 补充）**:
1. 打包脚本中对必要文件使用 bare `cp`（不要 `if [ -f ]; then cp; fi`）。`set -euo pipefail` + bare cp = 文件缺失时立即报错退出；`if` 保护会静默跳过，掩盖打包遗漏。
2. release.yml 的 "Verify bundle integrity" 步骤在 codesign 前检查 5 个必要文件（executable、CLI、Info.plist、AppIcon.icns、SPM resource bundle），作为第二道防线。
**Evidence**: bundle.sh:40-43 有 `cp AppIcon.icns`，release.yml:47-68 缺少该步骤。CI 产出的 .app 在 Finder 中显示通用白纸图标。修复后 bundle.sh 移除 if 保护 + release.yml 添加 integrity check。
