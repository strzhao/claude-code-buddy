#!/bin/bash
# snip_concurrency_and_residual.acceptance.test.sh
#
# 红队验收测试：并发写 + 残留/human 项（黑盒 CLI 驱动 + VISUAL_RESIDUE 注释）
# 覆盖谓词：
#   AC-SNIP-15  并发写 → 原子写无丢失无损坏（length==预期 + jq 合法）
#   AC-SNIP-12  [det+human] 首次执行未信任拒执行；信任后放行（det-machine 切片可机器验，弹框留 QA）
#   AC-SNIP-13  [Phase 2] 加载无 tools 字段旧插件正常加载运行（Phase 1 不强求，注释登记）
#   AC-SNIP-16  [human] GUI 召唤 + Cmd+V 粘贴（VISUAL_RESIDUE 留 QA 真机判定）
#
# 红队红线：det-machine 强断言；human 标 VISUAL_RESIDUE 不强求自动化

set -u
set -o pipefail

PASS=0; FAIL=0; SKIP=0
FAILMSGS=()

export BUDDY_TEST_HOME="${BUDDY_TEST_HOME:-$(mktemp -d -t snip-conc-acceptance)}"
mkdir -p "$BUDDY_TEST_HOME/.buddy"
export HOME="$BUDDY_TEST_HOME"
BUDDY="${BUDDY_BIN:-buddy}"

fail() { FAIL=$((FAIL+1)); FAILMSGS+=("FAIL [$1]: $2"); echo "  ✗ FAIL [$1]: $2" >&2; }
pass() { PASS=$((PASS+1)); echo "  ✓ PASS [$1]"; }
skip() { SKIP=$((SKIP+1)); echo "  ⊘ SKIP [$1]: $2"; }

test_AC_SNIP_15() {
    echo "AC-SNIP-15: 并发写 → 原子写无丢失无损坏"
    # 策略：并发 run snip 多次（del via snip selection；add 走设置页 GUI shell 无法驱动）
    # 由于 shell 测试无 LLM 走 add 路径困难，改用 del 路径并发：
    # 预置 N 条 → 并发 del N 条 → length==0 + jq 合法
    local n=5 i arr=()
    # 构造 5 条
    arr=()
    for ((i=0;i<n;i++)); do
        arr+=("{\"keyword\":\"k$i\",\"content\":\"v$i\",\"created_at\":\"x\",\"updated_at\":\"x\"}")
    done
    local joined
    joined=$(IFS=,; echo "[${arr[*]}]")
    mkdir -p "$HOME/.buddy"
    printf '%s' "$joined" > "$HOME/.buddy/snippets.json"

    # 并发 del 5 条
    for ((i=0;i<n;i++)); do
        "$BUDDY" launcher run snip --input "$(jq -rn --arg k "k$i" '{query:$k,selection:("del:"+$k)}')" >/dev/null 2>&1 &
    done
    wait

    local len jq_ok
    len=$(jq length "$HOME/.buddy/snippets.json" 2>/dev/null)
    jq . "$HOME/.buddy/snippets.json" >/dev/null 2>&1 && jq_ok=1 || jq_ok=0

    if [ "$jq_ok" != "1" ]; then
        fail "AC-SNIP-15" "并发后 jq 不合法（损坏）"
        return
    fi
    if [ "$len" != "0" ]; then
        fail "AC-SNIP-15" "并发 del 后 length 期望 0，实际 $len（有丢失/未删/重复）"
        return
    fi
    pass "AC-SNIP-15"
}

test_AC_SNIP_12_det_slice() {
    echo "AC-SNIP-12 [det 切片]: 未信任 → run 返回 status:error message 含 not trusted + exit≠0"
    # 重置 trust：删 trust.json 中 snip 对应条目（简化：删整个 trust.json）
    rm -f "$HOME/.buddy/launcher-trust.json"
    seed_snippets '[{"keyword":"sig","content":"张三","created_at":"x","updated_at":"x"}]'
    pbcopy "BEFORE_TRUST" 2>/dev/null

    # 未信任 run：期望 status:error / message 含 not trusted + exit≠0 + pbpaste 未变
    local out exit_code paste msg status
    out="$("$BUDDY" launcher run snip --input '{"query":"sig"}' --json 2>&1 || true)"
    exit_code=$?
    paste=$(pbpaste 2>/dev/null || true)
    msg=$(echo "$out" | jq -r '.message // .data.message // empty' 2>/dev/null)
    status=$(echo "$out" | jq -r '.status // empty' 2>/dev/null)

    # 「未信任」预期：exit≠0 OR status=error OR message 含 not trusted
    local untrusted=0
    if [ "$exit_code" != "0" ]; then untrusted=1; fi
    if [ "$status" = "error" ]; then untrusted=1; fi
    if echo "$msg" | grep -qi "not trusted"; then untrusted=1; fi

    if [ "$untrusted" != "1" ]; then
        fail "AC-SNIP-12" "未信任期望被拒（exit≠0 / status=error / message 含 not trusted），实际 exit=$exit_code status=$status msg=$msg"
        return
    fi
    # pbpaste 未变（未信任未执行 → 未 autoCopy）
    if [ "$paste" != "BEFORE_TRUST" ]; then
        fail "AC-SNIP-12" "未信任 pbpaste 期望 'BEFORE_TRUST'（未执行），实际 '$paste'"
        return
    fi
    # VISUAL_RESIDUE: 信任后放行 + GUI 弹框留 QA 真机判定（无法纯 shell 自动化）
    echo "  ⊘ VISUAL_RESIDUE AC-SNIP-12 [human]: 信任后放行 + GUI 信任弹框 → 留 QA 真机判定"
    pass "AC-SNIP-12 [det 切片]"
}

test_AC_SNIP_13_note() {
    echo "AC-SNIP-13 [Phase 2]: 加载无 tools 字段旧插件正常加载运行"
    # AC-SNIP-13 是 Phase 2 形态2 改造点（C7 向后兼容：新 tools 字段 decodeIfPresent，旧 plugin.json 零破坏）
    # Phase 1 范围内不强求（无 tools 字段是当前默认），但 C7 契约已声明 decodeIfPresent
    # 此处登记注释，Phase 2 task 落地后补充测试
    skip "AC-SNIP-13" "Phase 2 形态2 范围（tools 字段向后兼容），Phase 1 不强求自动化"
}

test_AC_SNIP_16_note() {
    echo "AC-SNIP-16 [human]: GUI 召唤 snip sig 回车 + 第三方应用 Cmd+V 粘贴 == 片段"
    # 跨应用 Cmd+V 真机验证无法纯 shell 自动化（依赖 GUI 自动化 + 第三方应用前置）
    # autoCopy 框架行为已在 CommandAutoCopyExtAcceptance.test.swift + AC-SNIP-01 pbpaste 断言覆盖
    # VISUAL_RESIDUE: 留 QA 真机判定
    echo "  ⊘ VISUAL_RESIDUE AC-SNIP-16 [human]: 跨应用 Cmd+V → 留 QA 真机判定"
    skip "AC-SNIP-16" "human 谓词（跨应用 Cmd+V），依赖扩展 A 的 pbpaste 断言已在 AC-SNIP-01/CommandAutoCopyExt 覆盖"
}

echo "=== snip concurrency + residual acceptance tests ==="
echo "BUDDY=$BUDDY  HOME=$HOME"
echo

test_AC_SNIP_15
test_AC_SNIP_12_det_slice
test_AC_SNIP_13_note
test_AC_SNIP_16_note

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
    for m in "${FAILMSGS[@]}"; do echo "$m"; done
    exit 1
fi
exit 0
