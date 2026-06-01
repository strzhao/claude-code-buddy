# macOS 案例不敏感 FS 让 git mv Tests/ 与 git mv tests/ 在 tree 中合并为单一目录

<!-- tags: macos, git-mv, case-insensitive, monorepo, refactor, apfs, tests -->
**Scenario**: Swift 工程同时有根级 `Tests/`（XCTest 单元测试）和 `tests/`（bash 验收测试）两个目录。`git mv Tests apps/desktop/Tests && git mv tests apps/desktop/tests` 在 macOS APFS（案例不敏感）上看似合法，但 git 索引最终只保留一个 lowercase `apps/desktop/tests/`，把 Tests/BuddyCoreTests 与 tests/acceptance 的内容混进同一目录。Package.swift 的 `path: "Tests/BuddyCoreTests"` 在 macOS 上仍能解析（FS 不区分大小写），但 git ls-files 显示真实路径是 lowercase——在 case-sensitive Linux CI 上会失败（本项目恰好用 macOS runner，未触发）。
**Lesson**: 案例不敏感 FS 上同名（仅大小写不同）目录的 git mv 不安全。修复方案：要么 (a) 把 `tests/` 先 rename 成不冲突的临时名再操作（如 `tests_tmp`）；要么 (b) 接受 lowercase 合并后把 Package.swift path 也改为 lowercase 以与 git tree 一致；要么 (c) 在 case-sensitive volume（如 Linux 容器或 case-sensitive APFS 卷）上做 rename 后 push 回来。本项目当前选 (b) 的 latent 接受 + 文档化，因 macOS-only CI 不暴露问题。通用规则：任何跨目录 rename 操作前，先 grep 是否有同名仅大小写不同的目录。
**Evidence**: 红队验收测试在 `[ ! -d $REPO_ROOT/Tests ]` 断言上永久 FAIL（macOS 把 Tests/ 解析到 tests/integration/）；契约 C4 文档化为 known latent inconsistency。
