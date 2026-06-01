# lint-staged 给 tsc 追加文件参数会绕过 tsconfig.json，用函数形式忽略文件列表

<!-- tags: lint-staged, tsc, tsconfig, hook, pre-commit, husky, tsconfig-bypass -->
**Scenario**: `.lintstagedrc.json` 写 `"packages/skin-cli/**/*.ts": ["tsc --noEmit"]`，pre-commit hook 触发时 lint-staged 把暂存的 .ts 文件路径追加到命令尾，变成 `tsc --noEmit src/index.ts`。此时 tsc **完全忽略** tsconfig.json（包括 `esModuleInterop`、`moduleResolution: "bundler"` 等），导致 `import archiver from 'archiver'` 报 TS1259 "Module can only be default-imported using esModuleInterop flag"。
**Lesson**: 任何需要按 tsconfig 行为运行的命令，不能直接接 lint-staged 追加的文件参数。修复模式：把 lintstagedrc 改为 `.mjs` 用**函数形式**返回固定命令字符串：`"packages/skin-cli/**/*.ts": () => "pnpm --filter @stringzhao/skin-cli exec tsc -p tsconfig.json --noEmit"`。函数形式 lint-staged 不会追加文件参数。通用规则：任何依赖项目配置文件（jest.config / eslint.config / tsconfig）的命令在 lint-staged 中都该用函数形式。
**Evidence**: 本任务 commit 阶段 pre-commit hook 触发 TS1259 失败，commit-agent 把 `.lintstagedrc.json` 改为 `.lintstagedrc.mjs` 函数形式后通过。
