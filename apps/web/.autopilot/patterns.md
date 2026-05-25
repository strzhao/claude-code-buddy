### [2026-04-18] Vitest API route 测试必须用 node 环境而非 jsdom

<!-- tags: vitest, testing, api, jsdom -->

**Scenario**: 在 Vitest 中直接 import Next.js App Router route handler 并构造 `Request` + `FormData` 进行集成测试
**Lesson**: jsdom 环境下的 `File` 类与 Node.js 内置 `undici` 的 `File` 类不同，导致 `file instanceof File` 在 route handler 中返回 false。API route 测试文件顶部必须加 `// @vitest-environment node` 指令切换到 Node 环境。
**Evidence**: `__tests__/api/upload.test.ts` 在 jsdom 环境中 POST /api/upload 全部返回 400 "No file provided"，切换 node 环境后 6/6 通过。

### [2026-04-18] Next.js 16 error.tsx 使用 unstable_retry 而非 reset

<!-- tags: nextjs, error-boundary, breaking-change -->

**Scenario**: 创建 `src/app/error.tsx` 错误边界组件
**Lesson**: Next.js 16.2.0 起 error.tsx 的 props 从 `{ error, reset }` 变为 `{ error, unstable_retry }`。`reset` 仍然存在但语义不同（仅清除错误状态不重新获取）。使用旧 API 会导致 TypeScript 类型错误。始终查阅 `node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/error.md`。
**Evidence**: Next.js 16 文档 error.md 第 117 行明确标注 `unstable_retry` 为 v16.2.0 新增。

### [2026-04-18] React 19 set-state-in-effect lint 规则要求异步包裹

<!-- tags: react, lint, useEffect, setState -->

**Scenario**: `useEffect` 内调用含 `setState` 的函数触发 `react-hooks/set-state-in-effect` 错误
**Lesson**: React 19 的 ESLint 规则 `react-hooks/set-state-in-effect` 禁止在 effect body 中同步调用 setState。即使 `setLoading(true)` 只是初始化状态也不行。修复方法：将所有 setState 调用包裹在 effect 内部定义的 async 函数中，effect body 只调用该函数。
**Evidence**: `AdminDashboard.tsx` 第 48 行 `fetchSkins(activeTab)` → ESLint error。重构为 `const load = async () => { setLoading(true); ... }; load();` 后 lint 通过。

### [2026-04-20] fix-dog-preview 脚本 Redis 键名必须与 constants.ts 一致

<!-- tags: redis, scripts, constants, skin-store -->

**Scenario**: 创建独立脚本直接操作 Redis 时，硬编码了键名 `"skin-ids:all"` 而非使用项目常量
**Lesson**: `REDIS_INDEX_ALL = "skin-ids"`（无 `:all` 后缀）。独立脚本不依赖项目路径别名时，仍需核对 `src/lib/constants.ts` 中的实际键名。硬编码错误键名会导致脚本静默失效（查到 0 条记录）却不报错。
**Evidence**: Code quality reviewer 发现 `smembers("skin-ids:all")` 查空集合。改为 `"skin-ids"` 后匹配。
