# 红队验收断言的机制精确性（grep 命中注释 / regex 语序反 → 对正确 impl 误报）

<!-- tags: red-team, acceptance-test, false-positive, grep, regex, comment-matching, yaml, release-yml, test-precision, mutation-survival, autopilot, qa, bash, shell-test -->

**Scenario**: 红队 SC1 断言「release.yml 含 fetch-plugins 且在 swift build 之前」，用 `grep -n "fetch-plugins" | head -1` 对 `grep -n "swift build" | head -1` 比行号。但 release.yml 的**注释**里含这些字面量（`# 在 swift build 之前` / `# Makefile fetch-plugins target`），grep 命中注释行 → 行号误判 fetch(38)≥swift(36) → 对**正确** impl（实际 `run:` fetch@39 < swift@42）误报 FAIL。同类：SC7 regex `内置(插件)?(保留|留内置)` 要求「内置」在前，但实际文案「保留内置」/「留内置」是「内置」在后 → 不匹配 → 误报。

**Lesson**:
- **断言要匹配「机制」不是「字面量」**：验证 YAML/代码顺序时，grep `run:` 命令行（`^[[:space:]]*run:.*X`）而非裸字符串（会命中注释/step name）。验证文案约定时，regex 要覆盖实际语序（`保留内置|留内置|内置保留`），不能只写一种。
- **红队 false-positive 的危害**：对正确 impl 误报 → 编排器要么误判 impl 偏离设计（错打回蓝队），要么被迫「修测试」（模糊红队 sanctity 边界）。两者都浪费 + 动摇红队权威性。
- **区分「弱化测试让 broken impl 过」(禁止) vs「修测试机制缺陷」(必要)**：判据 = 独立读 impl 文件核验是否真满足契约意图。本次 SC1（release.yml 顺序真正确）/SC7（CLAUDE.md 真有约定）属后者——修机制（grep `run:` / regex 兼容语序）后 impl 仍通过 = 真修复非弱化；加锁重跑 + qa-reviewer 独立核验确认。

**How to apply**:
- 红队写 grep/regex 断言前先自问「这 pattern 会不会命中注释/无关行/反语序」。
- YAML 顺序断言：`^[[:space:]]*run:.*<cmd>` 只匹配命令行，跳过注释与 step name。
- 文案断言：枚举实际可能表述，或用更宽语义匹配（别锁死单一语序）。
- 编排器遇红队 FAIL：先独立核验 impl 是否真满足契约——满足而测试误报 → 修测试机制（非弱化），重加锁 + 重跑，并在 QA 报告透明声明（让 qa-reviewer 独立复核「非掩盖」）。

**关联**: [[2026-06-23-autopilot-red-team-false-report-verify-ls]]（红队虚报，编排器 find/ls 验证）、[[2026-06-24-red-team-helper-masked-backward-compat-tier1-5]]（红队 helper 默认填字段掩盖边界）、本次 SC1/SC7（autopilot 社区插件化任务，commit 3729d3f）。
