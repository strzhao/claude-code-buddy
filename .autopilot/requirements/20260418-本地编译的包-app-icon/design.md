**目标**：用行走猫咪精灵图生成新 AppIcon.icns，并修复 CI release 打包流程

**根因**：release.yml "Assemble .app bundle" 步骤缺少 AppIcon.icns 复制（bundle.sh 有但 CI 没有）

**方案**：
1. 用 Python PIL 将 `cat-walk-a-1.png` 按 nearest-neighbor 缩放生成多分辨率 iconset → iconutil 转 .icns
2. 在 release.yml 第 60 行后添加 `cp Sources/.../AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"`

**文件影响**：
| 文件 | 操作 | 说明 |
|------|------|------|
| Sources/ClaudeCodeBuddy/Resources/AppIcon.icns | 替换 | 新行走猫咪 icon |
| .github/workflows/release.yml | 修改 | 添加 icon 复制步骤 |
