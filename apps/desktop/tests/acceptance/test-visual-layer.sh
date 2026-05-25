#!/usr/bin/env bash
# Acceptance Test: Visual Layer (003-visual-layer)
# Verifies that CatSprite gains hitbox constant, label/color properties, configure
# and updateLabel methods, and that all colorBlendFactor = 0 literals are replaced
# with sessionTintFactor.  Also verifies BuddyScene wires up configure and
# implements updateCatLabel (not a stub).

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAT_SRC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/CatSprite.swift"
SCENE_SRC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Visual Layer (003-visual-layer) ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# ── Assertion 1: swift build succeeds (hard stop) ────────────────────────────
echo "[1] swift build succeeds with no errors..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0"
else
    fail "swift build failed (non-zero exit)"
    echo "    Build must succeed before source-level checks are meaningful."
    echo ""
    echo "--- Visual Layer Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi

# ── Assertion 2: CatSprite.hitboxSize constant ───────────────────────────────
echo "[2] CatSprite declares static let hitboxSize..."
if grep -q 'static let hitboxSize' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.hitboxSize constant found"
else
    fail "CatSprite.hitboxSize NOT found in $CAT_SRC"
fi

# ── Assertion 3: CatSprite.labelNode property ────────────────────────────────
echo "[3] CatSprite declares labelNode as SKLabelNode?..."
if grep -qE 'labelNode.*SKLabelNode' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.labelNode: SKLabelNode? property found"
else
    fail "CatSprite.labelNode (SKLabelNode?) NOT found in $CAT_SRC"
fi

# ── Assertion 4: CatSprite.sessionColor property ────────────────────────────
echo "[4] CatSprite declares sessionColor as SessionColor?..."
if grep -qE 'sessionColor.*SessionColor' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.sessionColor: SessionColor? property found"
else
    fail "CatSprite.sessionColor (SessionColor?) NOT found in $CAT_SRC"
fi

# ── Assertion 5: CatSprite.sessionTintFactor default value ──────────────────
echo "[5] CatSprite declares sessionTintFactor = 0.3..."
if grep -qE 'sessionTintFactor.*0\.3' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.sessionTintFactor = 0.3 found"
else
    fail "CatSprite.sessionTintFactor = 0.3 NOT found in $CAT_SRC"
fi

# ── Assertion 6: CatSprite.configure method ──────────────────────────────────
echo "[6] CatSprite has func configure..."
if grep -q 'func configure' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.configure method found"
else
    fail "CatSprite.configure method NOT found in $CAT_SRC"
fi

# ── Assertion 7: CatSprite.updateLabel method ────────────────────────────────
echo "[7] CatSprite has func updateLabel..."
if grep -q 'func updateLabel' "$CAT_SRC" 2>/dev/null; then
    pass "CatSprite.updateLabel method found"
else
    fail "CatSprite.updateLabel method NOT found in $CAT_SRC"
fi

# ── Assertion 8: No bare colorBlendFactor = 0 literals remain ───────────────
echo "[8] No remaining 'colorBlendFactor = 0' literals in CatSprite..."
# grep exits 0 if a match IS found (bad), exits 1 if no match found (good).
if grep -q 'colorBlendFactor = 0' "$CAT_SRC" 2>/dev/null; then
    REMAINING=$(grep -n 'colorBlendFactor = 0' "$CAT_SRC")
    fail "Found bare 'colorBlendFactor = 0' that should have been replaced with sessionTintFactor:"$'\n'"$REMAINING"
else
    pass "No bare 'colorBlendFactor = 0' literals remain in CatSprite"
fi

# ── Assertion 9: sessionTintFactor appears 8+ times in CatSprite ─────────────
echo "[9] sessionTintFactor used 8+ times in state transitions..."
TINT_COUNT=$(grep -c 'sessionTintFactor' "$CAT_SRC" 2>/dev/null || echo 0)
if [ "$TINT_COUNT" -ge 8 ]; then
    pass "sessionTintFactor appears $TINT_COUNT times (>= 8 required)"
else
    fail "sessionTintFactor appears only $TINT_COUNT time(s) in $CAT_SRC; expected 8+"
fi

# ── Assertion 10: BuddyScene calls .configure( ───────────────────────────────
echo "[10] BuddyScene calls cat.configure(...)..."
if grep -qE '\.configure\(' "$SCENE_SRC" 2>/dev/null; then
    pass "BuddyScene calls .configure( found"
else
    fail "BuddyScene .configure( call NOT found in $SCENE_SRC"
fi

# ── Assertion 11: BuddyScene.updateCatLabel is not a stub ────────────────────
echo "[11] BuddyScene.updateCatLabel is implemented (not a stub)..."
if grep -q 'updateCatLabel' "$SCENE_SRC" 2>/dev/null; then
    if grep -i 'stub' "$SCENE_SRC" 2>/dev/null | grep -qi 'updateCatLabel\|Stub'; then
        fail "BuddyScene.updateCatLabel appears to still be a stub"
    else
        # Confirm the function body does something meaningful (calls updateLabel)
        if grep -A5 'updateCatLabel' "$SCENE_SRC" 2>/dev/null | grep -q 'updateLabel'; then
            pass "BuddyScene.updateCatLabel is implemented and calls updateLabel"
        else
            pass "BuddyScene.updateCatLabel exists and does not contain 'Stub'"
        fi
    fi
else
    fail "updateCatLabel NOT found in $SCENE_SRC"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Visual Layer Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
