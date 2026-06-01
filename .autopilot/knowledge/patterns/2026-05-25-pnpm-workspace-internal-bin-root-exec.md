# pnpm workspace 内部包的 bin 不会自动暴露给根 pnpm exec，需声明为 root workspace 依赖

<!-- tags: pnpm, workspace, bin, exec, monorepo, devDependency -->
**Scenario**: monorepo 新增 `packages/skin-cli/`（@stringzhao/skin-cli, bin: buddy-skin）后，在仓库根执行 `pnpm exec buddy-skin --help` 报 `Command "buddy-skin" not found`。即使 `pnpm --filter @stringzhao/skin-cli exec buddy-skin` 也找不到。直接 `node packages/skin-cli/dist/index.js` 才能工作。
**Lesson**: pnpm 不会自动把内部 workspace package 的 bin 链接到根 `node_modules/.bin/`——因为 root 没有声明对这些包的依赖。修复模式：把内部包加为根 package.json 的 devDependency 用 `workspace:*` 协议（`"@stringzhao/skin-cli": "workspace:*"`），下一次 `pnpm install` 会把 bin 链到 root `.bin/`。通用规则：内部 CLI 包要从根可调用时必须声明依赖；纯库包不需要（消费者会自己声明）。
**Evidence**: QA Wave 1.5 场景 4 发现此缺口，本任务通过加 root devDep 修复，红队契约 C3 `pnpm exec buddy-skin --help` 断言恢复 PASS。
