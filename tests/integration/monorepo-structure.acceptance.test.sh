#!/usr/bin/env bash
# monorepo-structure.acceptance.test.sh
# 验收测试：验证 claude-code-buddy monorepo 整合后的静态结构与配置内容
# 基于设计文档契约 C1-C7，完全从黑盒视角验证——不依赖任何运行时构建
#
# CONTRACT: C1-C7 from state.md 设计文档
#
# 用法:
#   bash tests/integration/monorepo-structure.acceptance.test.sh
#   # 或从仓库根执行（推荐）
#
# 退出码: 0 = 全部通过, 非零 = 至少一个断言失败

set -euo pipefail

# ── 工具可用性检查 ─────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq 未安装，无法运行本测试（需要 jq 解析 JSON）"
  exit 2
fi

# yq 用于 YAML 解析，若不可用则使用 grep 降级
USE_YQ=false
if command -v yq &>/dev/null; then
  USE_YQ=true
fi

# ── 仓库根定位 ─────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── 颜色（非终端时禁用）────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

separator() { printf '%s\n' "────────────────────────────────────────────────────────"; }

# ── 断言函数 ──────────────────────────────────────────────────────────────────
FAILED=0
TOTAL=0

assert() {
  local description="$1"
  local condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition"; then
    echo -e "  ${GREEN}✅ $description${RESET}"
  else
    echo -e "  ${RED}❌ FAIL: $description${RESET}"
    echo "     condition: $condition"
    FAILED=$((FAILED + 1))
  fi
}

# ── 辅助：从 JSON 文件取字段值 ────────────────────────────────────────────────
json_field() {
  local file="$1"
  local query="$2"
  jq -r "$query" "$file" 2>/dev/null
}

# ── 辅助：检查文件内含指定字符串 ─────────────────────────────────────────────
file_contains() {
  local file="$1"
  local pattern="$2"
  grep -qF "$pattern" "$file" 2>/dev/null
}

# ── 辅助：检查文件不含指定字符串 ─────────────────────────────────────────────
file_not_contains() {
  local file="$1"
  local pattern="$2"
  ! grep -qF "$pattern" "$file" 2>/dev/null
}

echo ""
echo -e "${BOLD}Claude Code Buddy — Monorepo 结构验收测试${RESET}"
echo "仓库根: $REPO_ROOT"
echo "$(date)"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C1. pnpm workspace 拓扑契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C1] pnpm workspace 拓扑契约${RESET}"
separator

WORKSPACE_YAML="$REPO_ROOT/pnpm-workspace.yaml"
ROOT_PKG="$REPO_ROOT/package.json"
PNPM_LOCK="$REPO_ROOT/pnpm-lock.yaml"

assert "pnpm-workspace.yaml 文件存在" "[ -f '$WORKSPACE_YAML' ]"
assert "pnpm-lock.yaml 文件存在" "[ -f '$PNPM_LOCK' ]"
assert "根 package.json 文件存在" "[ -f '$ROOT_PKG' ]"

# pnpm-workspace.yaml 包含 apps/* 与 packages/* 两条 glob
assert "pnpm-workspace.yaml 含 apps/* glob" "file_contains '$WORKSPACE_YAML' 'apps/*'"
assert "pnpm-workspace.yaml 含 packages/* glob" "file_contains '$WORKSPACE_YAML' 'packages/*'"

# 根 package.json 字段验证
assert "根 package.json name === 'claude-code-buddy'" \
  "[ \"\$(json_field '$ROOT_PKG' '.name')\" = 'claude-code-buddy' ]"

assert "根 package.json private === true" \
  "[ \"\$(json_field '$ROOT_PKG' '.private')\" = 'true' ]"

assert "根 package.json packageManager 字段含 'pnpm@'" \
  "[[ \"\$(json_field '$ROOT_PKG' '.packageManager')\" == pnpm@* ]]"

assert "根 package.json engines.node 声明至少 >=20" \
  "json_field '$ROOT_PKG' '.engines.node' | grep -qE '>=20'"

assert "根 package.json 不含 workspaces 字段" \
  "[ \"\$(json_field '$ROOT_PKG' '.workspaces')\" = 'null' ]"

# pnpm workspace 包列表包含必要包（通过检查各包的 package.json 来间接验证）
assert "pnpm -r ls 可枚举 @stringzhao/web（apps/web/package.json 存在）" \
  "[ -f '$REPO_ROOT/apps/web/package.json' ]"

assert "pnpm -r ls 可枚举 @stringzhao/skin-cli（packages/skin-cli/package.json 存在）" \
  "[ -f '$REPO_ROOT/packages/skin-cli/package.json' ]"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C2. @stringzhao/web 包契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C2] @stringzhao/web 包契约${RESET}"
separator

WEB_PKG="$REPO_ROOT/apps/web/package.json"
WEB_DIR="$REPO_ROOT/apps/web"

assert "apps/web/package.json 存在" "[ -f '$WEB_PKG' ]"

assert "apps/web package.json name === '@stringzhao/web'" \
  "[ \"\$(json_field '$WEB_PKG' '.name')\" = '@stringzhao/web' ]"

assert "apps/web package.json private === true" \
  "[ \"\$(json_field '$WEB_PKG' '.private')\" = 'true' ]"

# scripts 必需字段存在性
for script_key in dev build start lint test test:watch test:e2e test:acceptance; do
  assert "apps/web scripts 含 '$script_key'" \
    "[ \"\$(json_field '$WEB_PKG' '.scripts[\"$script_key\"]')\" != 'null' ]"
done

# test 命令精确匹配
assert "apps/web scripts.test === 'vitest run -c vitest.config.mts'（精确匹配 -c 参数）" \
  "[ \"\$(json_field '$WEB_PKG' '.scripts.test')\" = 'vitest run -c vitest.config.mts' ]"

# test:acceptance 命令精确匹配
assert "apps/web scripts[\"test:acceptance\"] === 'vitest run -c vitest.config.ts'" \
  "[ \"\$(json_field '$WEB_PKG' '.scripts[\"test:acceptance\"]')\" = 'vitest run -c vitest.config.ts' ]"

# prepare:husky 不应存在于 apps/web
assert "apps/web scripts 不含 prepare: husky（移到根）" \
  "[ \"\$(json_field '$WEB_PKG' '.scripts.prepare')\" != 'husky' ]"

# 必需配置文件存在
for cfg_file in next.config.ts middleware.ts tsconfig.json vitest.config.mts vitest.config.ts \
                playwright.config.ts postcss.config.mjs eslint.config.mjs .prettierrc.json; do
  assert "apps/web/$cfg_file 文件存在" "[ -f '$WEB_DIR/$cfg_file' ]"
done

# 不应含 .husky/
assert "apps/web 不含 .husky/ 目录（已移到根）" "[ ! -d '$WEB_DIR/.husky' ]"

# 不应含 .lintstagedrc.json
assert "apps/web 不含 .lintstagedrc.json（已移到根）" "[ ! -f '$WEB_DIR/.lintstagedrc.json' ]"

# 不应含 commitlint.config.js
assert "apps/web 不含 commitlint.config.js（已移到根）" "[ ! -f '$WEB_DIR/commitlint.config.js' ]"

# 不应含 package-lock.json（pnpm-lock.yaml 接管）
assert "apps/web 不含 package-lock.json（pnpm 接管锁文件）" "[ ! -f '$WEB_DIR/package-lock.json' ]"

# 不应含 cli/ 子目录（已移到 packages/skin-cli）
assert "apps/web 不含 cli/ 子目录（已移到 packages/skin-cli）" "[ ! -d '$WEB_DIR/cli' ]"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C3. @stringzhao/skin-cli 包契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C3] @stringzhao/skin-cli 包契约${RESET}"
separator

SKIN_CLI_PKG="$REPO_ROOT/packages/skin-cli/package.json"
SKIN_CLI_DIR="$REPO_ROOT/packages/skin-cli"

assert "packages/skin-cli/package.json 存在" "[ -f '$SKIN_CLI_PKG' ]"

assert "packages/skin-cli package.json name === '@stringzhao/skin-cli'" \
  "[ \"\$(json_field '$SKIN_CLI_PKG' '.name')\" = '@stringzhao/skin-cli' ]"

assert "packages/skin-cli package.json private === true" \
  "[ \"\$(json_field '$SKIN_CLI_PKG' '.private')\" = 'true' ]"

assert "packages/skin-cli package.json type === 'module'" \
  "[ \"\$(json_field '$SKIN_CLI_PKG' '.type')\" = 'module' ]"

assert "packages/skin-cli package.json bin[\"buddy-skin\"] === './dist/index.js'" \
  "[ \"\$(json_field '$SKIN_CLI_PKG' '.bin[\"buddy-skin\"]')\" = './dist/index.js' ]"

assert "packages/skin-cli package.json scripts.build === 'tsc'" \
  "[ \"\$(json_field '$SKIN_CLI_PKG' '.scripts.build')\" = 'tsc' ]"

assert "packages/skin-cli/src/index.ts 文件存在" "[ -f '$SKIN_CLI_DIR/src/index.ts' ]"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C4. apps/desktop Swift 工程契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C4] apps/desktop Swift 工程契约${RESET}"
separator

DESKTOP_DIR="$REPO_ROOT/apps/desktop"

# 必须存在的路径（8 个）
assert "apps/desktop/Package.swift 存在" "[ -f '$DESKTOP_DIR/Package.swift' ]"
assert "apps/desktop/Sources/App/ 目录或 main.swift 存在" \
  "[ -d '$DESKTOP_DIR/Sources/App' ] || [ -f '$DESKTOP_DIR/Sources/App/main.swift' ]"
assert "apps/desktop/Sources/BuddyCLI/ 目录存在" "[ -d '$DESKTOP_DIR/Sources/BuddyCLI' ]"
assert "apps/desktop/Sources/ClaudeCodeBuddy/ 目录存在" "[ -d '$DESKTOP_DIR/Sources/ClaudeCodeBuddy' ]"
assert "apps/desktop/Tests/BuddyCoreTests/ 目录存在" "[ -d '$DESKTOP_DIR/Tests/BuddyCoreTests' ]"
assert "apps/desktop/tests/acceptance/ 目录存在" "[ -d '$DESKTOP_DIR/tests/acceptance' ]"
assert "apps/desktop/Scripts/ 目录存在" "[ -d '$DESKTOP_DIR/Scripts' ]"
assert "apps/desktop/Makefile 文件存在" "[ -f '$DESKTOP_DIR/Makefile' ]"

# 根目录不再含有已搬迁的文件/目录（6 个）
assert "仓库根不再有 Package.swift（已搬迁到 apps/desktop）" "[ ! -f '$REPO_ROOT/Package.swift' ]"
assert "仓库根不再有 Sources/ 目录（已搬迁到 apps/desktop）" "[ ! -d '$REPO_ROOT/Sources' ]"
# 注：macOS 案例不敏感 FS 上 Tests/ 与 tests/ 同名；改为检查具体子目录已搬走（与 C4 契约一致：允许根级 tests/integration/）
assert "仓库根不再有 Tests/BuddyCoreTests（XCTest 已搬到 apps/desktop）" "[ ! -d '$REPO_ROOT/Tests/BuddyCoreTests' ]"
assert "仓库根不再有 tests/acceptance（bash 验收已搬到 apps/desktop）" "[ ! -d '$REPO_ROOT/tests/acceptance' ]"
assert "仓库根不再有 Scripts/ 目录（已搬迁到 apps/desktop）" "[ ! -d '$REPO_ROOT/Scripts' ]"
assert "仓库根不再有 Makefile（已搬迁到 apps/desktop）" "[ ! -f '$REPO_ROOT/Makefile' ]"

# Package.swift 内 path: 字段使用相对路径风格（不含 apps/desktop/ 前缀）
DESKTOP_PKG_SWIFT="$DESKTOP_DIR/Package.swift"
if [ -f "$DESKTOP_PKG_SWIFT" ]; then
  assert "apps/desktop/Package.swift 含 path: \"Sources/App\"（相对风格）" \
    "file_contains '$DESKTOP_PKG_SWIFT' 'path: \"Sources/App\"' || file_contains '$DESKTOP_PKG_SWIFT' 'path: .Sources/App.'"
  assert "apps/desktop/Package.swift 含 path: \"Sources/BuddyCLI\"（相对风格）" \
    "file_contains '$DESKTOP_PKG_SWIFT' 'path: \"Sources/BuddyCLI\"' || file_contains '$DESKTOP_PKG_SWIFT' 'path: .Sources/BuddyCLI.'"
  assert "apps/desktop/Package.swift 含 path: \"Sources/ClaudeCodeBuddy\"（相对风格）" \
    "file_contains '$DESKTOP_PKG_SWIFT' 'path: \"Sources/ClaudeCodeBuddy\"' || file_contains '$DESKTOP_PKG_SWIFT' 'path: .Sources/ClaudeCodeBuddy.'"
  assert "apps/desktop/Package.swift 不含 apps/desktop/ 前缀（path 字段保持相对）" \
    "file_not_contains '$DESKTOP_PKG_SWIFT' 'apps/desktop/Sources'"
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C5. CI workflow 契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C5] CI workflow 契约${RESET}"
separator

WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
CI_DESKTOP="$WORKFLOWS_DIR/ci-desktop.yml"
CI_WEB="$WORKFLOWS_DIR/ci-web.yml"
RELEASE_YML="$WORKFLOWS_DIR/release.yml"
OLD_CI="$WORKFLOWS_DIR/ci.yml"

# ci-desktop.yml 存在性
assert ".github/workflows/ci-desktop.yml 文件存在" "[ -f '$CI_DESKTOP' ]"

# ci-desktop.yml 内容
if [ -f "$CI_DESKTOP" ]; then
  assert "ci-desktop.yml on.push.paths 含 apps/desktop/**" \
    "file_contains '$CI_DESKTOP' 'apps/desktop/**'"
  assert "ci-desktop.yml on.push.paths 不含 apps/web" \
    "file_not_contains '$CI_DESKTOP' 'apps/web'"
  assert "ci-desktop.yml on.push.paths 不含 packages" \
    "file_not_contains '$CI_DESKTOP' 'packages'"
  assert "ci-desktop.yml 含 working-directory: apps/desktop（swift/make 步骤限定目录）" \
    "file_contains '$CI_DESKTOP' 'working-directory: apps/desktop'"
fi

# ci-web.yml 存在性
assert ".github/workflows/ci-web.yml 文件存在" "[ -f '$CI_WEB' ]"

# ci-web.yml 内容
if [ -f "$CI_WEB" ]; then
  assert "ci-web.yml on.push.paths 含 apps/web/**" \
    "file_contains '$CI_WEB' 'apps/web/**'"
  assert "ci-web.yml on.push.paths 含 packages/**" \
    "file_contains '$CI_WEB' 'packages/**'"
  assert "ci-web.yml on.push.paths 不含 apps/desktop" \
    "file_not_contains '$CI_WEB' 'apps/desktop'"
  assert "ci-web.yml 含 pnpm/action-setup 字符串" \
    "file_contains '$CI_WEB' 'pnpm/action-setup'"
  assert "ci-web.yml 含 pnpm install --frozen-lockfile 字符串" \
    "file_contains '$CI_WEB' 'pnpm install --frozen-lockfile'"
fi

# release.yml 存在性
assert ".github/workflows/release.yml 文件存在" "[ -f '$RELEASE_YML' ]"

# release.yml 内容
if [ -f "$RELEASE_YML" ]; then
  assert "release.yml 至少 1 个 step 含 working-directory: apps/desktop" \
    "file_contains '$RELEASE_YML' 'working-directory: apps/desktop'"
  assert "release.yml 含 mv apps/desktop/ClaudeCodeBuddy-（zip 移到仓库根的关键 fix）" \
    "file_contains '$RELEASE_YML' 'mv apps/desktop/ClaudeCodeBuddy-'"
  assert "release.yml 含 *.zip ./ 字符串" \
    "file_contains '$RELEASE_YML' '*.zip ./'"
  # softprops/action-gh-release files: 字段不含 apps/desktop/ 前缀
  assert "release.yml softprops files: 字段为 ClaudeCodeBuddy-（不含 apps/desktop/ 前缀）" \
    "grep -q 'files:' '$RELEASE_YML' && grep -A2 'files:' '$RELEASE_YML' | grep -q 'ClaudeCodeBuddy-\${{ github.ref_name }}.zip'"
fi

# 旧 ci.yml 不应再存在
assert ".github/workflows/ci.yml（旧文件名）不再存在" "[ ! -f '$OLD_CI' ]"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C6. Git hooks 契约
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C6] Git hooks 契约${RESET}"
separator

HUSKY_PRE_COMMIT="$REPO_ROOT/.husky/pre-commit"
HUSKY_COMMIT_MSG="$REPO_ROOT/.husky/commit-msg"
LINTSTAGED_JSON="$REPO_ROOT/.lintstagedrc.json"
COMMITLINT_CJS="$REPO_ROOT/commitlint.config.cjs"
COMMITLINT_JS="$REPO_ROOT/commitlint.config.js"

assert ".husky/pre-commit 文件存在" "[ -f '$HUSKY_PRE_COMMIT' ]"
assert ".husky/commit-msg 文件存在" "[ -f '$HUSKY_COMMIT_MSG' ]"

if [ -f "$HUSKY_PRE_COMMIT" ]; then
  assert ".husky/pre-commit 含 lint-staged 字符串" \
    "file_contains '$HUSKY_PRE_COMMIT' 'lint-staged'"
fi

if [ -f "$HUSKY_COMMIT_MSG" ]; then
  assert ".husky/commit-msg 含 commitlint 字符串" \
    "file_contains '$HUSKY_COMMIT_MSG' 'commitlint'"
fi

assert "根目录 .lintstagedrc.json 存在" "[ -f '$LINTSTAGED_JSON' ]"

if [ -f "$LINTSTAGED_JSON" ]; then
  assert ".lintstagedrc.json 至少含一个 apps/web/** 风格的 key" \
    "file_contains '$LINTSTAGED_JSON' 'apps/web/'"
fi

assert "根目录含 commitlint.config.cjs 或 commitlint.config.js" \
  "[ -f '$COMMITLINT_CJS' ] || [ -f '$COMMITLINT_JS' ]"

COMMITLINT_FILE=""
[ -f "$COMMITLINT_CJS" ] && COMMITLINT_FILE="$COMMITLINT_CJS"
[ -z "$COMMITLINT_FILE" ] && [ -f "$COMMITLINT_JS" ] && COMMITLINT_FILE="$COMMITLINT_JS"

if [ -n "$COMMITLINT_FILE" ]; then
  assert "commitlint 配置含 config-conventional 字符串" \
    "file_contains '$COMMITLINT_FILE' 'config-conventional'"
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# C7. 部署接口契约（不变项）
# ══════════════════════════════════════════════════════════════════════════════
separator
echo -e "${BOLD}[C7] 部署接口契约（不变项）${RESET}"
separator

SKIN_GALLERY_SWIFT="$REPO_ROOT/apps/desktop/Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift"
WEB_CLAUDE_MD="$REPO_ROOT/apps/web/CLAUDE.md"
CATALOG_URL="https://buddy.stringzhao.life/api/skins"

assert "apps/desktop/Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift 文件存在" \
  "[ -f '$SKIN_GALLERY_SWIFT' ]"

if [ -f "$SKIN_GALLERY_SWIFT" ]; then
  assert "SkinGalleryViewController.swift 仍含 catalogURL: https://buddy.stringzhao.life/api/skins" \
    "file_contains '$SKIN_GALLERY_SWIFT' '$CATALOG_URL'"
fi

assert "apps/web/CLAUDE.md 文件存在（部署变更文档）" "[ -f '$WEB_CLAUDE_MD' ]"

if [ -f "$WEB_CLAUDE_MD" ]; then
  assert "apps/web/CLAUDE.md 文末含 Vercel 字符串（部署步骤已记录）" \
    "file_contains '$WEB_CLAUDE_MD' 'Vercel'"
  assert "apps/web/CLAUDE.md 文末含 Root Directory 字符串（Vercel 配置已记录）" \
    "file_contains '$WEB_CLAUDE_MD' 'Root Directory'"
fi

# 跨契约一致性：catalogURL 在 desktop 和 web 两端保持一致（C7 跨层验证）
# web 端任何引用 catalogURL 的地方（env、config、src）都应与 desktop 保持一致
WEB_SRC_DIR="$REPO_ROOT/apps/web/src"
WEB_ENV_EXAMPLE="$REPO_ROOT/apps/web/.env.example"

# 验证 web 端没有写死不同的 catalogURL（若存在硬编码 URL 则应与 desktop 相同）
if [ -d "$WEB_SRC_DIR" ]; then
  # 如果 web src 中存在对 /api/skins 的引用，检查其 host 与 desktop 一致
  # 这是一个跨契约一致性断言
  WEB_CATALOG_REFERENCES=$(grep -r "buddy.stringzhao.life/api/skins" "$WEB_SRC_DIR" 2>/dev/null | wc -l | tr -d ' ')
  CONFLICTING_CATALOG=$(grep -r "\.life/api/skins" "$WEB_SRC_DIR" 2>/dev/null | grep -v "buddy.stringzhao.life" | wc -l | tr -d ' ')
  assert "apps/web/src 中不含与 desktop catalogURL 冲突的硬编码 API 地址" \
    "[ '$CONFLICTING_CATALOG' = '0' ]"
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# 测试摘要
# ══════════════════════════════════════════════════════════════════════════════
separator
PASSED=$((TOTAL - FAILED))
echo -e "${BOLD}测试摘要${RESET}"
echo "  总计: $TOTAL 个断言"
echo -e "  ${GREEN}通过: $PASSED${RESET}"
if [ "$FAILED" -gt 0 ]; then
  echo -e "  ${RED}失败: $FAILED${RESET}"
else
  echo -e "  ${GREEN}失败: 0${RESET}"
fi
separator

if [ "$FAILED" -gt 0 ]; then
  echo -e "${RED}${BOLD}FAILED — $FAILED 个断言未通过${RESET}"
  echo ""
  exit 1
else
  echo -e "${GREEN}${BOLD}ALL PASSED — $TOTAL 个断言全部通过${RESET}"
  echo ""
  exit 0
fi
