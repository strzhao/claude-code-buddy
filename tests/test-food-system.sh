#!/bin/bash
# Acceptance Test: Food System
# Verifies that FoodSprite, FoodManager, and all integration points exist and
# are structurally correct before runtime testing.
#
# Usage: bash tests/test-food-system.sh
# Exit code: 0 = all checks passed, non-zero = at least one check failed.

PASS=0
FAIL=0

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FOOD_SPRITE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/FoodSprite.swift"
FOOD_MANAGER="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/FoodManager.swift"
CAT_SPRITE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/CatSprite.swift"
BUDDY_SCENE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift"
SESSION_MANAGER="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Session/SessionManager.swift"
SESSION_ROW_VIEW="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift"
FOOD_ASSETS_DIR="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Assets/Food"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

check_file_exists() {
    local label="$1"
    local path="$2"
    echo "[A] $label exists..."
    if [ -f "$path" ]; then
        pass "$label exists at $path"
    else
        fail "$label NOT found at $path"
    fi
}

check_grep() {
    local label="$1"
    local pattern="$2"
    local file="$3"
    echo "[A] $label..."
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (pattern '$pattern' not found in $(basename "$file"))"
    fi
}

check_grep_absent() {
    local label="$1"
    local pattern="$2"
    local file="$3"
    echo "[A] $label..."
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (pattern '$pattern' unexpectedly found in $(basename "$file"))"
    fi
}

echo "=== Test: Food System ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# ── Section 1: File existence ─────────────────────────────────────────────────

echo "--- [Section 1] File existence ---"

check_file_exists "FoodSprite.swift"  "$FOOD_SPRITE"
check_file_exists "FoodManager.swift" "$FOOD_MANAGER"

echo ""

# ── Section 2: CatState.eating ────────────────────────────────────────────────

echo "--- [Section 2] CatState.eating enum case ---"

check_grep "CatState enum includes .eating case" \
    "case[[:space:]]+eating" "$CAT_SPRITE"

echo ""

# ── Section 3: PhysicsCategory.food ──────────────────────────────────────────

echo "--- [Section 3] PhysicsCategory.food constant ---"

check_grep "PhysicsCategory.food is defined" \
    "static[[:space:]]+let[[:space:]]+food" "$BUDDY_SCENE"

check_grep "PhysicsCategory.food has value 0x4" \
    "food[[:space:]]*:[[:space:]]*UInt32[[:space:]]*=[[:space:]]*0x4" "$BUDDY_SCENE"

echo ""

# ── Section 4: BuddyScene integration ────────────────────────────────────────

echo "--- [Section 4] BuddyScene integration ---"

check_grep "spawnFood method exists in BuddyScene" \
    "func[[:space:]]+spawnFood" "$BUDDY_SCENE"

check_grep "catPosition method exists in BuddyScene" \
    "func[[:space:]]+catPosition" "$BUDDY_SCENE"

check_grep "idleCats method exists in BuddyScene" \
    "func[[:space:]]+idleCats" "$BUDDY_SCENE"

check_grep "foodManager property exists in BuddyScene" \
    "foodManager" "$BUDDY_SCENE"

check_grep "didBegin contact handler exists in BuddyScene" \
    "func[[:space:]]+didBegin" "$BUDDY_SCENE"

echo "[A] setupGround includes PhysicsCategory.food in ground bitmasks..."
# setupGround must reference food so food collides with / contacts the ground.
# We check that both the method and 'food' appear within proximity by verifying
# food is referenced after the setupGround declaration before didChangeSize.
setup_ground_line=$(grep -n "func setupGround\|private func setupGround" "$BUDDY_SCENE" 2>/dev/null | head -1 | cut -d: -f1)
did_change_line=$(grep -n "func didChangeSize" "$BUDDY_SCENE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$setup_ground_line" ] && [ -n "$did_change_line" ]; then
    food_in_setup=$(awk "NR>$setup_ground_line && NR<$did_change_line && /food/" "$BUDDY_SCENE" | wc -l | tr -d ' ')
    if [ "$food_in_setup" -gt 0 ]; then
        pass "setupGround references PhysicsCategory.food in bitmasks"
    else
        fail "setupGround does NOT reference PhysicsCategory.food in bitmasks"
    fi
else
    fail "Could not locate setupGround or didChangeSize in BuddyScene.swift to verify food bitmask"
fi

echo "[A] didChangeSize includes PhysicsCategory.food in ground bitmasks..."
if [ -n "$did_change_line" ]; then
    food_in_resize=$(awk "NR>$did_change_line && /food/" "$BUDDY_SCENE" | head -20 | grep -c "food")
    if [ "$food_in_resize" -gt 0 ]; then
        pass "didChangeSize references PhysicsCategory.food in bitmasks"
    else
        fail "didChangeSize does NOT reference PhysicsCategory.food in bitmasks"
    fi
else
    fail "Could not locate didChangeSize in BuddyScene.swift to verify food bitmask"
fi

echo ""

# ── Section 5: FoodSprite API ─────────────────────────────────────────────────

echo "--- [Section 5] FoodSprite API ---"

check_grep "FoodState enum exists" \
    "enum[[:space:]]+FoodState" "$FOOD_SPRITE"

check_grep "FoodState has .falling case" \
    "case[[:space:]]+falling" "$FOOD_SPRITE"

check_grep "FoodState has .landed case" \
    "(case[[:space:]]+|,[[:space:]]*)landed" "$FOOD_SPRITE"

check_grep "FoodState has .claimed case" \
    "(case[[:space:]]+|,[[:space:]]*)claimed" "$FOOD_SPRITE"

check_grep "FoodState has .eaten case" \
    "(case[[:space:]]+|,[[:space:]]*)eaten" "$FOOD_SPRITE"

check_grep "FoodSprite.claim(by:) method exists" \
    "func[[:space:]]+claim\b" "$FOOD_SPRITE"

check_grep "FoodSprite.release() method exists" \
    "func[[:space:]]+release\b" "$FOOD_SPRITE"

check_grep "FoodSprite.eat(completion:) method exists" \
    "func[[:space:]]+eat\b" "$FOOD_SPRITE"

check_grep "FoodSprite.expire(completion:) method exists" \
    "func[[:space:]]+expire\b" "$FOOD_SPRITE"

echo ""

# ── Section 6: FoodManager API ────────────────────────────────────────────────

echo "--- [Section 6] FoodManager API ---"

check_grep "FoodManager.trySpawnFood method exists" \
    "func[[:space:]]+trySpawnFood" "$FOOD_MANAGER"

check_grep "FoodManager.foodLanded method exists" \
    "func[[:space:]]+foodLanded" "$FOOD_MANAGER"

check_grep "FoodManager.releaseFoodForCat method exists" \
    "func[[:space:]]+releaseFoodForCat" "$FOOD_MANAGER"

check_grep "FoodManager.maxConcurrentFoods constant exists" \
    "maxConcurrentFoods" "$FOOD_MANAGER"

check_grep "FoodManager.toolEndSpawnProbability constant exists" \
    "toolEndSpawnProbability" "$FOOD_MANAGER"

echo ""

# ── Section 7: CatSprite food methods ────────────────────────────────────────

echo "--- [Section 7] CatSprite food methods ---"

check_grep "CatSprite.walkToFood method exists" \
    "func[[:space:]]+walkToFood" "$CAT_SPRITE"

check_grep "CatSprite.startEating method exists" \
    "func[[:space:]]+startEating" "$CAT_SPRITE"

check_grep "CatSprite.currentTargetFood property exists" \
    "currentTargetFood" "$CAT_SPRITE"

check_grep "CatSprite.onFoodAbandoned callback exists" \
    "onFoodAbandoned" "$CAT_SPRITE"

echo ""

# ── Section 8: SessionManager trigger ────────────────────────────────────────

echo "--- [Section 8] SessionManager spawnFood trigger ---"

check_grep "spawnFood is called in SessionManager" \
    "spawnFood" "$SESSION_MANAGER"

echo ""

# ── Section 9: SessionRowView .eating case ────────────────────────────────────

echo "--- [Section 9] SessionRowView handles .eating state ---"

check_grep "SessionRowView handles .eating case in switch" \
    "case[[:space:]]+\.eating" "$SESSION_ROW_VIEW"

echo ""

# ── Section 10: Food assets ───────────────────────────────────────────────────

echo "--- [Section 10] Food assets ---"

echo "[A] Assets/Food/ directory exists..."
if [ -d "$FOOD_ASSETS_DIR" ]; then
    pass "Assets/Food/ directory exists"
else
    fail "Assets/Food/ directory NOT found at $FOOD_ASSETS_DIR"
fi

echo "[A] Assets/Food/ contains exactly 102 PNG files..."
png_count=$(find "$FOOD_ASSETS_DIR" -maxdepth 1 -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
if [ "$png_count" -eq 102 ]; then
    pass "Assets/Food/ contains 102 PNG files"
else
    fail "Assets/Food/ contains $png_count PNG files (expected 102)"
fi

echo ""

# ── Section 11: Swift build ───────────────────────────────────────────────────

echo "--- [Section 11] Swift build ---"

echo "[A] swift build compiles without errors..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0 (no compilation errors)"
else
    fail "swift build failed — implementation has compilation errors"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────

echo "=============================="
echo "Food System Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "=============================="

[ "$FAIL" -eq 0 ]
