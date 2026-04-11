#!/usr/bin/env bash
# Acceptance Test: Data Models (001-data-models)
# Verifies that SessionColor, SessionInfo, and HookMessage are defined correctly
# as specified in the 001-data-models task:
#   - SessionColor enum with 8 cases and hex/nsColor/ansi256 properties
#   - SessionInfo struct with all required fields
#   - HookMessage backward-compatible extensions (Optional cwd/label, setLabel event)

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COLOR_SRC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Session/SessionColor.swift"
INFO_SRC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Session/SessionInfo.swift"
HOOK_SRC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Network/HookMessage.swift"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Data Models (001-data-models) ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# ── Assertion 1: swift build succeeds ─────────────────────────────────────
echo "[1] swift build succeeds with no errors..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0"
else
    fail "swift build failed (non-zero exit)"
    echo "    Build must succeed before source-level checks are meaningful."
    echo ""
    echo "--- Data Models Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi

# ── Assertion 2: SessionColor has exactly 8 color cases ──────────────────
echo "[2] SessionColor enum has 8 color cases..."
# Count enum cases inside the SessionColor declaration.
# Each case is expected to appear as "case <name>" on its own line.
# Count enum cases inside the SessionColor declaration.
# The declaration line looks like: "case coral, teal, gold, violet, mint, peach, sky, rose"
# Count comma-separated identifiers on enum case lines (not switch cases which use .name:)
COLOR_CASE_LINE=$(awk '/enum SessionColor/,/^}/' "$COLOR_SRC" 2>/dev/null \
    | grep '^\s*case [a-z]' | head -1)
COLOR_CASE_COUNT=$(echo "$COLOR_CASE_LINE" | tr ',' '\n' | wc -l | tr -d ' ')
if [ "$COLOR_CASE_COUNT" -eq 8 ]; then
    pass "SessionColor has exactly 8 cases (found $COLOR_CASE_COUNT)"
else
    fail "SessionColor expected 8 cases, found $COLOR_CASE_COUNT"
fi

# ── Assertion 3: SessionColor has hex computed property ───────────────────
echo "[3] SessionColor has 'hex' computed property..."
if grep -q 'var hex' "$COLOR_SRC" 2>/dev/null; then
    pass "SessionColor.hex property exists"
else
    fail "SessionColor.hex property NOT found in $COLOR_SRC"
fi

# ── Assertion 4: SessionColor has nsColor computed property ───────────────
echo "[4] SessionColor has 'nsColor' computed property..."
if grep -q 'var nsColor' "$COLOR_SRC" 2>/dev/null; then
    pass "SessionColor.nsColor property exists"
else
    fail "SessionColor.nsColor property NOT found in $COLOR_SRC"
fi

# ── Assertion 5: SessionColor has ansi256 computed property ───────────────
echo "[5] SessionColor has 'ansi256' computed property..."
if grep -q 'var ansi256' "$COLOR_SRC" 2>/dev/null; then
    pass "SessionColor.ansi256 property exists"
else
    fail "SessionColor.ansi256 property NOT found in $COLOR_SRC"
fi

# ── Assertion 6: SessionInfo has all required fields ─────────────────────
echo "[6] SessionInfo struct declares all required fields..."
REQUIRED_FIELDS=(sessionId label color cwd pid state lastActivity)
ALL_OK=true
for field in "${REQUIRED_FIELDS[@]}"; do
    if grep -qE "(let|var) $field" "$INFO_SRC" 2>/dev/null; then
        :
    else
        fail "SessionInfo field '$field' NOT found in $INFO_SRC"
        ALL_OK=false
    fi
done
if $ALL_OK; then
    pass "SessionInfo has all required fields: ${REQUIRED_FIELDS[*]}"
fi

# ── Assertion 7: HookMessage cwd is Optional (String?) ───────────────────
echo "[7] HookMessage.cwd is Optional (String?)..."
if grep -q 'cwd.*String?' "$HOOK_SRC" 2>/dev/null || \
   grep -q 'var cwd.*:.*String?' "$HOOK_SRC" 2>/dev/null; then
    pass "HookMessage.cwd is declared as Optional String?"
else
    fail "HookMessage.cwd Optional type (String?) NOT found in $HOOK_SRC"
fi

# ── Assertion 8: HookMessage label is Optional (String?) ─────────────────
echo "[8] HookMessage.label is Optional (String?)..."
if grep -q 'label.*String?' "$HOOK_SRC" 2>/dev/null || \
   grep -q 'var label.*:.*String?' "$HOOK_SRC" 2>/dev/null; then
    pass "HookMessage.label is declared as Optional String?"
else
    fail "HookMessage.label Optional type (String?) NOT found in $HOOK_SRC"
fi

# ── Assertion 9: HookEvent.setLabel case exists ──────────────────────────
echo "[9] HookEvent.setLabel case exists..."
if grep -q 'setLabel\|set_label' "$HOOK_SRC" 2>/dev/null; then
    pass "HookEvent.setLabel case found in $HOOK_SRC"
else
    fail "HookEvent.setLabel case NOT found in $HOOK_SRC"
fi

# ── Assertion 10: HookEvent.setLabel raw value is "set_label" ───────────
echo "[10] HookEvent.setLabel raw value is \"set_label\"..."
if grep -q '"set_label"' "$HOOK_SRC" 2>/dev/null; then
    pass "HookEvent.setLabel raw value \"set_label\" found"
else
    fail "HookEvent.setLabel raw value \"set_label\" NOT found in $HOOK_SRC"
fi

# ── Assertion 11: catState mapping returns nil for setLabel ──────────────
echo "[11] catState mapping returns nil for .setLabel..."
# The catState computed property should explicitly return nil for .setLabel.
# We look for the pattern: case .setLabel followed by nil (possibly on next line).
if grep -A2 '\.setLabel' "$HOOK_SRC" 2>/dev/null | grep -q 'nil\|return nil'; then
    pass "catState returns nil for .setLabel"
elif grep -q 'setLabel.*nil\|nil.*setLabel' "$HOOK_SRC" 2>/dev/null; then
    pass "catState returns nil for .setLabel"
else
    fail "catState nil mapping for .setLabel NOT found in $HOOK_SRC"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- Data Models Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
