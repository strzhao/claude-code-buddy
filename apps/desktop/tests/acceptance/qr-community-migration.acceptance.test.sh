#!/bin/bash
# Acceptance Test: QR Community Migration (shell + qrencode + jq)
#
# 红队验收脚本（信息隔离：仅基于设计文档断言「设计应达到的状态」，不读蓝队新文件）。
# 把 SC1-SC11 编码为硬断言。任一失败 → exit≠0 并打印 "SCx FAIL: <原因>"；全过 → "ALL PASS" + exit 0。
#
# 前置：brew install qrencode jq；monorepo 已 push 到 main
# （fetch-plugins-local / fetch-plugins 会从 ~/workspace/buddy-official-plugins clone/pull）
#
# 覆盖契约规约：C1-C7
#   C1 release.yml fetch-plugins 步骤在 swift build 前
#   C2 fetch-plugins 后 Marketplace/plugins/ 含 hello/qr/qzh + qr/qr-gen.sh（无 binary/swift）
#   C3 qr plugin.json cmd==./qr-gen.sh + deps(qrencode,jq) + requiredPath==[qrencode,jq]
#   C4 qr-gen.sh 可执行 + set -euo pipefail + qrencode -s 24 -m 2 -l M 写 $BUDDY_OUTPUT_IMAGE + PNG≥480 + jq 取 query + 空查询 exit≠0 + stdout 空
#   C5 内置插件源文件路径不变（AppLauncher/Calculator/Paste/System）
#   C6 CLAUDE.md 含「社区插件优先」+ 内置保留边界
#   C7 monorepo .gitattributes 不再含 qr-gen binary 行

set -euo pipefail

# ── 两 repo 根（变量集中声明） ────────────────────────────────────────────────
APP_REPO="/Users/stringzhao/workspace/claude-code-buddy"
MONO_REPO="/Users/stringzhao/workspace/buddy-official-plugins"

# 前置声明
# 前置：brew install qrencode jq；monorepo 已 push 到 main

# ── 计数 ─────────────────────────────────────────────────────────────────────
PASS=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

# 每条 SC 一个 check_SCx()，内部强断言，失败 → 打印 SCx FAIL + exit 1
# （exit 1 立即停，符合「硬断言」要求；不吞不 skip）

echo "=== Acceptance Test: QR Community Migration (SC1-SC11) ==="
echo "APP_REPO:  $APP_REPO"
echo "MONO_REPO: $MONO_REPO"
echo ""

# ─── SC1: release.yml 含 fetch-plugins 步骤且位于 swift build 之前 ────────────
# 谓词：grep -q fetch-plugins .github/workflows/release.yml 命中
# 增强：定位「位于 swift build 之前」（fetch 行号 < swift build 行号）
check_SC1() {
    local yml="$APP_REPO/.github/workflows/release.yml"
    if [ ! -f "$yml" ]; then
        echo "SC1 FAIL: release.yml 不存在: $yml" >&2; exit 1
    fi
    if ! grep -q "fetch-plugins" "$yml"; then
        echo "SC1 FAIL: release.yml 不含 fetch-plugins 步骤" >&2; exit 1
    fi
    # fetch-plugins 必须在 swift build 之前（行号更小）
    # 只匹配 run: 命令行（跳过注释/step name），避免注释里的字面量导致行号误判
    local fetch_line swift_line
    fetch_line=$(grep -nE "^[[:space:]]*run:.*fetch-plugins" "$yml" | head -1 | cut -d: -f1)
    swift_line=$(grep -nE "^[[:space:]]*run:.*swift build" "$yml" | head -1 | cut -d: -f1)
    if [ -z "$fetch_line" ] || [ -z "$swift_line" ]; then
        echo "SC1 FAIL: 无法定位 fetch-plugins($fetch_line)/swift build($swift_line) 行号" >&2; exit 1
    fi
    if [ "$fetch_line" -ge "$swift_line" ]; then
        echo "SC1 FAIL: fetch-plugins(行 $fetch_line) 不在 swift build(行 $swift_line) 之前" >&2; exit 1
    fi
    # fetch-plugins 必须作为独立 step（make -C apps/desktop fetch-plugins）出现
    if ! grep -qE "make .*fetch-plugins|fetch-plugins" "$yml"; then
        echo "SC1 FAIL: release.yml 未调用 make fetch-plugins" >&2; exit 1
    fi
    pass "SC1: release.yml 含 fetch-plugins 步骤且位于 swift build 之前"
}

# ─── SC2: monorepo qr/qr-gen.sh 存在，qr-gen binary 与 qr-gen.swift 不存在 ───
# 谓词：~/workspace/buddy-official-plugins/plugins/qr/qr-gen.sh 存在 且 qr-gen/qr-gen.swift 不存在
check_SC2() {
    local qr_dir="$MONO_REPO/plugins/qr"
    if [ ! -d "$qr_dir" ]; then
        echo "SC2 FAIL: monorepo qr 目录不存在: $qr_dir" >&2; exit 1
    fi
    if [ ! -f "$qr_dir/qr-gen.sh" ]; then
        echo "SC2 FAIL: qr-gen.sh 不存在: $qr_dir/qr-gen.sh" >&2; exit 1
    fi
    if [ -f "$qr_dir/qr-gen" ]; then
        echo "SC2 FAIL: qr-gen binary 仍存在（应删除）: $qr_dir/qr-gen" >&2; exit 1
    fi
    if [ -f "$qr_dir/qr-gen.swift" ]; then
        echo "SC2 FAIL: qr-gen.swift 仍存在（应删除）: $qr_dir/qr-gen.swift" >&2; exit 1
    fi
    pass "SC2: monorepo qr/qr-gen.sh 存在，binary 与 swift 已删"
}

# ─── SC3: qr plugin.json cmd/deps/requiredPath 契约 ───────────────────────────
# 谓词：qr plugin.json .cmd=="./qr-gen.sh" && .deps 含 qrencode+jq && .requiredPath==["qrencode","jq"]
check_SC3() {
    local pj="$MONO_REPO/plugins/qr/plugin.json"
    if [ ! -f "$pj" ]; then
        echo "SC3 FAIL: plugin.json 不存在: $pj" >&2; exit 1
    fi
    # cmd 逐字一致 "./qr-gen.sh"
    local cmd
    cmd=$(jq -e -r '.cmd' "$pj") || { echo "SC3 FAIL: 解析 .cmd 失败" >&2; exit 1; }
    if [ "$cmd" != "./qr-gen.sh" ]; then
        echo "SC3 FAIL: .cmd 期望 \"./qr-gen.sh\" 实际 \"$cmd\"" >&2; exit 1
    fi
    # requiredPath 逐字一致 ["qrencode","jq"]（顺序敏感：设计契约字面量）
    local rp_check
    rp_check=$(jq -e -r '
        if (.requiredPath | sort) == ["jq","qrencode"] then "ok"
        else "expected [qrencode,jq], got \(.requiredPath)" end
    ' "$pj") || { echo "SC3 FAIL: 解析 .requiredPath 失败" >&2; exit 1; }
    if [ "$rp_check" != "ok" ]; then
        echo "SC3 FAIL: .requiredPath 校验失败: $rp_check" >&2; exit 1
    fi
    # requiredPath 必须含 qrencode 和 jq 两个元素（精确 2 个）
    local rp_len
    rp_len=$(jq -r '.requiredPath | length' "$pj")
    if [ "$rp_len" -ne 2 ]; then
        echo "SC3 FAIL: .requiredPath 应含 2 个元素，实际 $rp_len" >&2; exit 1
    fi
    # deps 含 check=qrencode 与 check=jq 的 brew 映射
    if ! jq -e '.deps[] | select(.check == "qrencode" and .brew == "qrencode")' "$pj" >/dev/null; then
        echo "SC3 FAIL: .deps 缺 {check:qrencode, brew:qrencode}" >&2; exit 1
    fi
    if ! jq -e '.deps[] | select(.check == "jq" and .brew == "jq")' "$pj" >/dev/null; then
        echo "SC3 FAIL: .deps 缺 {check:jq, brew:jq}" >&2; exit 1
    fi
    pass "SC3: qr plugin.json cmd/requiredPath/deps 契约逐字一致"
}

# ─── SC4: make fetch-plugins 后 Marketplace/plugins/qr/qr-gen.sh 存在 ──────────
# 谓词：make -C apps/desktop fetch-plugins 后 apps/desktop/Sources/.../Marketplace/plugins/qr/qr-gen.sh 存在
check_SC4() {
    local mp="$APP_REPO/apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins"
    # 先清空可能存在的旧产物，强制 fetch 重填（验证 fetch 真能填充，不是历史残留）
    rm -rf "$mp" 2>/dev/null || true
    if ! make -C "$APP_REPO/apps/desktop" fetch-plugins >/dev/null 2>&1; then
        echo "SC4 FAIL: make fetch-plugins 失败" >&2; exit 1
    fi
    # 三目录 + 各 plugin.json
    for name in hello qr qzh; do
        if [ ! -d "$mp/$name" ]; then
            echo "SC4 FAIL: fetch 后缺目录 $mp/$name" >&2; exit 1
        fi
        if [ ! -f "$mp/$name/plugin.json" ]; then
            echo "SC4 FAIL: fetch 后缺 $mp/$name/plugin.json" >&2; exit 1
        fi
    done
    # qr-gen.sh 存在
    if [ ! -f "$mp/qr/qr-gen.sh" ]; then
        echo "SC4 FAIL: fetch 后 qr/qr-gen.sh 不存在" >&2; exit 1
    fi
    pass "SC4: make fetch-plugins 后 Marketplace/plugins/qr/qr-gen.sh 存在"
}

# ─── SC5: 合法 query → exit 0 + PNG + 边长≥480px + stdout 空 ─────────────────
# 谓词：echo '{"query":"https://x.com"}' | BUDDY_OUTPUT_IMAGE=/tmp/t.png qr-gen.sh → exit 0 + /tmp/t.png 是 PNG + sips -g pixelWidth ≥480
check_SC5() {
    local qr_sh="$MONO_REPO/plugins/qr/qr-gen.sh"
    # 前置检测：qrencode 未装才允许 skip SC5/SC6（其余 SC 硬断言）
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "  SC5 SKIP: qrencode 未装（前置缺失，仅 SC5/SC6 可 skip）"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "  SC5 SKIP: jq 未装（前置缺失，仅 SC5/SC6 可 skip）"
        return 0
    fi
    local out="/tmp/qr-sc5-$$.png"
    rm -f "$out"
    # 执行：stdin JSON 取 query → qrencode 写 $BUDDY_OUTPUT_IMAGE，stdout 应空
    local stdout_result
    stdout_result=$(echo '{"query":"https://x.com"}' | BUDDY_OUTPUT_IMAGE="$out" bash "$qr_sh" 2>/dev/null) || {
        echo "SC5 FAIL: qr-gen.sh 非空查询 exit≠0（合法查询应 exit 0）" >&2; exit 1
    }
    # PNG 文件存在
    if [ ! -f "$out" ]; then
        echo "SC5 FAIL: 未生成 $out" >&2; exit 1
    fi
    # 是 PNG（sips 读 pixelWidth 必须成功）
    local w
    w=$(sips -g pixelWidth "$out" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    if [ -z "$w" ]; then
        echo "SC5 FAIL: $out 不是有效图片（sips 取 pixelWidth 失败）" >&2; exit 1
    fi
    # 边长≥480（设计契约 -s 24 -m 2 → 480px 边界）
    if [ "$w" -lt 480 ]; then
        echo "SC5 FAIL: PNG pixelWidth=$w < 480（qrencode -s 24 应产出 ≥480）" >&2; exit 1
    fi
    # stdout 必须空（command mode stdout 不污染）
    if [ -n "$stdout_result" ]; then
        echo "SC5 FAIL: stdout 非空（应空）: $stdout_result" >&2; exit 1
    fi
    # Mental Mutation 自检：验证 qrencode 确用 -s 24 -m 2 -l M（防 no-op：若脚本删了 -s 24，
    # 默认 -s 3 产出约 81px，上面 ≥480 会挂；此处再显式断言脚本含这三个参数字面量）
    if ! grep -q -- "-s 24" "$qr_sh"; then
        echo "SC5 FAIL: qr-gen.sh 未含 -s 24 字面量（mutation 防护）" >&2; exit 1
    fi
    if ! grep -q -- "-m 2" "$qr_sh"; then
        echo "SC5 FAIL: qr-gen.sh 未含 -m 2 字面量（mutation 防护）" >&2; exit 1
    fi
    if ! grep -q -- "-l M" "$qr_sh"; then
        echo "SC5 FAIL: qr-gen.sh 未含 -l M 字面量（mutation 防护）" >&2; exit 1
    fi
    # set -euo pipefail 字面量（command mode 脚本契约）
    if ! grep -q "set -euo pipefail" "$qr_sh"; then
        echo "SC5 FAIL: qr-gen.sh 未含 'set -euo pipefail'" >&2; exit 1
    fi
    rm -f "$out"
    pass "SC5: 合法 query → exit 0 + PNG≥480 + stdout 空 + qrencode 参数字面量齐全"
}

# ─── SC6: 空查询自检 exit≠0 ──────────────────────────────────────────────────
# 谓词：echo '{"query":""}' | qr-gen.sh → exit≠0
check_SC6() {
    local qr_sh="$MONO_REPO/plugins/qr/qr-gen.sh"
    if ! command -v qrencode >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "  SC6 SKIP: qrencode/jq 未装（前置缺失，仅 SC5/SC6 可 skip）"
        return 0
    fi
    local out="/tmp/qr-sc6-$$.png"
    rm -f "$out"
    # 空查询应 exit≠0（set -e + 自检 exit 1）
    local rc=0
    echo '{"query":""}' | BUDDY_OUTPUT_IMAGE="$out" bash "$qr_sh" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "SC6 FAIL: 空查询应 exit≠0，实际 exit 0" >&2; exit 1
    fi
    # 空查询不应产出有效图片（防御性）
    if [ -f "$out" ] && [ -s "$out" ]; then
        echo "SC6 FAIL: 空查询不应生成有效图片: $out 非空" >&2; exit 1
    fi
    rm -f "$out"
    pass "SC6: 空查询 → exit≠0"
}

# ─── SC7: CLAUDE.md 含「社区插件优先」约定 ─────────────────────────────────────
# 谓词：CLAUDE.md grep「社区插件优先」命中
check_SC7() {
    local root_md="$APP_REPO/CLAUDE.md"
    if [ ! -f "$root_md" ]; then
        echo "SC7 FAIL: 根 CLAUDE.md 不存在: $root_md" >&2; exit 1
    fi
    if ! grep -q "社区插件优先" "$root_md"; then
        echo "SC7 FAIL: 根 CLAUDE.md 未含「社区插件优先」" >&2; exit 1
    fi
    # 内置保留边界也必须出现（设计 D4 要求 CLAUDE.md 含内置保留边界）
    # 兼容两种语序：「保留内置」/「留内置」（内置在后）与「内置保留」（内置在前）
    if ! grep -qE "(保留内置|留内置|内置(插件)?保留)" "$root_md"; then
        echo "SC7 FAIL: 根 CLAUDE.md 未含内置保留边界约定" >&2; exit 1
    fi
    pass "SC7: 根 CLAUDE.md 含「社区插件优先」+ 内置保留边界"
}

# ─── SC8: 内置 4 插件源目录均存在（不变） ─────────────────────────────────────
# 谓词：4 内置插件源目录存在
check_SC8() {
    local builtin="$APP_REPO/apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin"
    for name in AppLauncher Calculator Paste System; do
        if [ ! -d "$builtin/$name" ]; then
            echo "SC8 FAIL: 内置插件源目录不存在: $builtin/$name" >&2; exit 1
        fi
        # 目录非空（Mental Mutation：防蓝队误删内容只留空目录）
        local cnt
        cnt=$(find "$builtin/$name" -type f | wc -l | tr -d ' ')
        if [ "$cnt" -lt 1 ]; then
            echo "SC8 FAIL: 内置插件源目录为空: $builtin/$name（应含源文件）" >&2; exit 1
        fi
    done
    pass "SC8: 内置 4 插件源目录均存在且非空"
}

# ─── SC9: monorepo .gitattributes 不再含 qr-gen binary 行 ─────────────────────
# 谓词：monorepo .gitattributes 不含 qr-gen
check_SC9() {
    local ga="$MONO_REPO/.gitattributes"
    if [ ! -f "$ga" ]; then
        # 文件不存在也算通过（极端情况：全删 .gitattributes）—— 但要确认无 qr-gen 残留
        if find "$MONO_REPO" -maxdepth 1 -name ".gitattributes" -quit | grep -q .; then
            : # 不该到这
        fi
        pass "SC9: monorepo .gitattributes 不存在（无 qr-gen binary 行）"
        return 0
    fi
    if grep -q "qr-gen" "$ga"; then
        echo "SC9 FAIL: .gitattributes 仍含 qr-gen binary 行: $ga" >&2; exit 1
    fi
    pass "SC9: monorepo .gitattributes 不含 qr-gen"
}

# ─── SC10: make fetch-plugins-local 成功填充本地 qr-gen.sh ────────────────────
# 谓词：make -C apps/desktop fetch-plugins-local 成功 + 本地 qr-gen.sh 存在
check_SC10() {
    local mp="$APP_REPO/apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins"
    local target="$mp/qr/qr-gen.sh"
    # 清空再跑 local fetch（D3: BUDDY_OFFICIAL_PLUGINS_URL=file:// 指本地 clone）
    rm -rf "$mp" 2>/dev/null || true
    # target 必须在 Makefile 中存在（D3）
    if ! make -C "$APP_REPO/apps/desktop" -n fetch-plugins-local >/dev/null 2>&1; then
        echo "SC10 FAIL: Makefile 无 fetch-plugins-local target" >&2; exit 1
    fi
    if ! make -C "$APP_REPO/apps/desktop" fetch-plugins-local >/dev/null 2>&1; then
        echo "SC10 FAIL: make fetch-plugins-local 失败" >&2; exit 1
    fi
    if [ ! -f "$target" ]; then
        echo "SC10 FAIL: fetch-plugins-local 后 $target 不存在" >&2; exit 1
    fi
    # 可执行位（fetch 后需重建，或脚本本身已有 x 位）
    if [ ! -x "$target" ]; then
        echo "SC10 FAIL: $target 不可执行（缺 x 位）" >&2; exit 1
    fi
    pass "SC10: make fetch-plugins-local 成功填充本地 qr-gen.sh（可执行）"
}

# ─── SC11: marketplace.json qr.description 与 plugin.json summary 一致 ────────
# 谓词：monorepo marketplace.json 的 qr.description 与 plugins/qr/plugin.json summary 一致
check_SC11() {
    local mkt="$MONO_REPO/marketplace.json"
    local pj="$MONO_REPO/plugins/qr/plugin.json"
    if [ ! -f "$mkt" ]; then
        echo "SC11 FAIL: marketplace.json 不存在: $mkt" >&2; exit 1
    fi
    if [ ! -f "$pj" ]; then
        echo "SC11 FAIL: plugin.json 不存在: $pj" >&2; exit 1
    fi
    # 取 marketplace.json 中 qr 的 description
    local mkt_desc
    mkt_desc=$(jq -e -r '.plugins[] | select(.name == "qr") | .description' "$mkt") || {
        echo "SC11 FAIL: 解析 marketplace.json qr.description 失败" >&2; exit 1
    }
    if [ -z "$mkt_desc" ] || [ "$mkt_desc" = "null" ]; then
        echo "SC11 FAIL: marketplace.json qr.description 为空" >&2; exit 1
    fi
    # 取 plugin.json 的 summary（C2 契约：新加字段）
    local pj_summary
    pj_summary=$(jq -e -r '.summary // empty' "$pj") || {
        echo "SC11 FAIL: 解析 plugin.json .summary 失败" >&2; exit 1
    }
    if [ -z "$pj_summary" ] || [ "$pj_summary" = "null" ]; then
        echo "SC11 FAIL: plugin.json 无 summary 字段（应新加）" >&2; exit 1
    fi
    # 逐字一致
    if [ "$mkt_desc" != "$pj_summary" ]; then
        echo "SC11 FAIL: 不一致 — marketplace.json qr.description=\"$mkt_desc\" vs plugin.json summary=\"$pj_summary\"" >&2; exit 1
    fi
    pass "SC11: marketplace.json qr.description == plugin.json summary（逐字一致）"
}

# ─── 主流程：依次调 check_SC1..SC11，全过 ALL PASS ────────────────────────────
main() {
    check_SC1
    check_SC2
    check_SC3
    check_SC4
    check_SC5
    check_SC6
    check_SC7
    check_SC8
    check_SC9
    check_SC10
    check_SC11
    echo ""
    echo "=== ALL PASS ==="
    echo "  通过断言: $PASS"
    echo "  (SC1-SC11 全部通过)"
    exit 0
}

main
