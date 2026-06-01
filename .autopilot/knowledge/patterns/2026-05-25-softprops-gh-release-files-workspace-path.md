# softprops/action-gh-release 的 files: 字段路径解析基于 GITHUB_WORKSPACE 而非 step working-directory

<!-- tags: github-actions, release, working-directory, glob, softprops, files, monorepo -->
**Scenario**: monorepo 把 Swift 工程搬到 apps/desktop/ 后，release.yml 给 `swift build`/`zip` step 加了 `working-directory: apps/desktop`，zip 产物落在 apps/desktop/ClaudeCodeBuddy-*.zip。但 `softprops/action-gh-release` 的 `files: ClaudeCodeBuddy-*.zip` 在 runner 上由 `@actions/glob` 解析，**基础路径是 `GITHUB_WORKSPACE`（仓库根）而非该 step 的 working-directory**。结果：release 创建成功但附件为空（action 找不到文件）。
**Lesson**: 任何 composite action 的输入字段（uses 后跟 with 块）都**不**继承 step 级别的 `working-directory`——它们运行在 action 自己的执行上下文中。修复模式：在 zip step 之后立即加一个独立 step `mv apps/desktop/ClaudeCodeBuddy-*.zip ./`（无 working-directory，默认在仓库根），保持 `files:` 字段写死的相对路径不变。通用规则：迁移工程到子目录时，全量 grep `uses:`，检查每个 action 是否依赖路径，必要时把产物 `mv` 回根目录。
**Evidence**: plan-reviewer Agent 审查时指出此 BLOCKER；本任务在 design 阶段写入契约 C5 + 实施任务 T7.3 显式 mv 步骤。
