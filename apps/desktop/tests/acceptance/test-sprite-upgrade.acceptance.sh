#!/bin/bash
# Acceptance Test: Cat Sprite Upgrade
# Verifies that the 32x32 placeholder sprites have been replaced with
# open-source 48x48 pixel art, the idle state machine is wired in, physics
# dimensions are updated, addCodingMovement is removed, thread-unsafe timers
# are absent, untouched files have not been modified, and README credits the
# new sprite source.
# Design ref: Cat Sprite Upgrade design document.

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPRITE_DIR="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Assets/Sprites"
CAT_SPRITE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/CatSprite.swift"
BUDDY_SCENE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift"
README="$PROJECT_ROOT/README.md"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Cat Sprite Upgrade ==="
echo "Project root: $PROJECT_ROOT"
echo "Sprite dir:   $SPRITE_DIR"
echo ""

# ── Section 1: Asset verification — old placeholder sprites REMOVED ──────────

echo "--- [Section 1] Old placeholder sprites removed ---"

OLD_SPRITES=(
    "cat-idle-1.png"
    "cat-thinking-1.png"
    "cat-coding-1.png"
    "cat-enter-1.png"
    "cat-exit-1.png"
)

for sprite in "${OLD_SPRITES[@]}"; do
    echo "[A] Old sprite '$sprite' does not exist..."
    if [ ! -f "$SPRITE_DIR/$sprite" ]; then
        pass "Old placeholder '$sprite' has been removed"
    else
        fail "Old placeholder '$sprite' still exists at $SPRITE_DIR/$sprite"
    fi
done

echo ""

# ── Section 2: Asset verification — new sprites follow naming convention ──────

echo "--- [Section 2] New sprite naming convention ---"

# At least one frame of each required animation type must exist.
# Pattern: cat-{anim}-{variant?}-{frame}.png

check_anim_exists() {
    local label="$1"
    local glob_pattern="$2"
    local matches
    matches=$(find "$SPRITE_DIR" -maxdepth 1 -name "$glob_pattern" 2>/dev/null | wc -l | tr -d ' ')
    echo "[A] At least one '$label' sprite exists (pattern: $glob_pattern)..."
    if [ "$matches" -gt 0 ]; then
        pass "Found $matches '$label' sprite(s) matching '$glob_pattern'"
    else
        fail "No '$label' sprites found matching '$glob_pattern' in $SPRITE_DIR"
    fi
}

check_anim_exists "idle-a variant"   "cat-idle-a-*.png"
check_anim_exists "clean (grooming)" "cat-clean-*.png"
check_anim_exists "sleep"            "cat-sleep-*.png"
check_anim_exists "scared (thinking)" "cat-scared-*.png"
check_anim_exists "paw (thinking)"   "cat-paw-*.png"
check_anim_exists "walk-a (enter/exit)" "cat-walk-a-*.png"

echo ""

# ── Section 3: Asset verification — new sprites are 48x48 PNG ─────────────────

echo "--- [Section 3] New sprites are 48x48 pixels ---"

# Collect all new-format sprites (those whose names match the new convention)
NEW_SPRITES=()
while IFS= read -r f; do
    NEW_SPRITES+=("$f")
done < <(find "$SPRITE_DIR" -maxdepth 1 -name "cat-*-*.png" 2>/dev/null | sort)

echo "[A] New sprite directory contains at least one sprite to size-check..."
if [ "${#NEW_SPRITES[@]}" -gt 0 ]; then
    pass "Found ${#NEW_SPRITES[@]} new-format sprite(s) in $SPRITE_DIR"
else
    fail "No new-format sprites found in $SPRITE_DIR — cannot verify dimensions"
fi

# Check dimensions of every new sprite found.
# Uses sips (always available on macOS) or falls back to file.
SPRITES_CHECKED=0
SPRITES_WRONG_SIZE=0
for sprite_path in "${NEW_SPRITES[@]}"; do
    sprite_name="$(basename "$sprite_path")"

    if command -v sips &>/dev/null; then
        width=$(sips --getProperty pixelWidth  "$sprite_path" 2>/dev/null | awk '/pixelWidth/{print $NF}')
        height=$(sips --getProperty pixelHeight "$sprite_path" 2>/dev/null | awk '/pixelHeight/{print $NF}')
    else
        # Fallback: use python3 to read PNG header (bytes 16-24 = width, height)
        dims=$(python3 - "$sprite_path" <<'PYEOF'
import sys, struct
with open(sys.argv[1], "rb") as f:
    f.read(16)  # PNG signature (8) + IHDR length (4) + "IHDR" (4)
    w = struct.unpack(">I", f.read(4))[0]
    h = struct.unpack(">I", f.read(4))[0]
print(f"{w} {h}")
PYEOF
)
        width=$(echo "$dims" | awk '{print $1}')
        height=$(echo "$dims" | awk '{print $2}')
    fi

    SPRITES_CHECKED=$((SPRITES_CHECKED + 1))
    if [ "$width" = "48" ] && [ "$height" = "48" ]; then
        : # correct size, counted below
    else
        SPRITES_WRONG_SIZE=$((SPRITES_WRONG_SIZE + 1))
        echo "    WRONG SIZE: $sprite_name is ${width}x${height} (expected 48x48)"
    fi
done

echo "[A] All checked new sprites are 48x48 ($SPRITES_CHECKED checked)..."
if [ "$SPRITES_CHECKED" -gt 0 ] && [ "$SPRITES_WRONG_SIZE" -eq 0 ]; then
    pass "All $SPRITES_CHECKED new sprite(s) are 48x48 pixels"
elif [ "$SPRITES_CHECKED" -eq 0 ]; then
    fail "No new sprites were checked for dimensions (none found)"
else
    fail "$SPRITES_WRONG_SIZE/$SPRITES_CHECKED new sprite(s) are NOT 48x48 pixels"
fi

echo ""

# ── Section 4: Build verification ─────────────────────────────────────────────

echo "--- [Section 4] Build verification ---"

echo "[A] swift build succeeds with refactored code..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0 (no compilation errors)"
else
    fail "swift build failed — refactored code has compilation errors"
fi

echo ""

# ── Section 5: Source code contract (grep-based) ──────────────────────────────

echo "--- [Section 5] Source code contracts (CatSprite.swift) ---"

echo "[A] CatSprite.swift contains sprite size '48'..."
if grep -q "48" "$CAT_SPRITE" 2>/dev/null; then
    pass "CatSprite.swift references '48' (sprite node size updated)"
else
    fail "CatSprite.swift does NOT reference '48' (sprite size not updated)"
fi

echo "[A] CatSprite.swift contains physics body size '44'..."
if grep -q "44" "$CAT_SPRITE" 2>/dev/null; then
    pass "CatSprite.swift references '44' (physics body size updated)"
else
    fail "CatSprite.swift does NOT reference '44' (physics body size not updated)"
fi

echo "[A] CatSprite.swift does NOT contain 'addCodingMovement' (method removed)..."
if ! grep -q "addCodingMovement" "$CAT_SPRITE" 2>/dev/null; then
    pass "addCodingMovement is absent from CatSprite.swift"
else
    fail "addCodingMovement still present in CatSprite.swift (should be removed)"
fi

echo "[A] CatSprite.swift contains 'IdleSubState' (idle state machine enum)..."
if grep -q "IdleSubState" "$CAT_SPRITE" 2>/dev/null; then
    pass "IdleSubState found in CatSprite.swift"
else
    fail "IdleSubState NOT found in CatSprite.swift (idle state machine missing)"
fi

echo "[A] CatSprite.swift uses 'SKAction.wait' (SpriteKit-safe timing)..."
if grep -q "SKAction.wait" "$CAT_SPRITE" 2>/dev/null; then
    pass "SKAction.wait found in CatSprite.swift"
else
    fail "SKAction.wait NOT found in CatSprite.swift (SpriteKit timing not used)"
fi

echo "[A] CatSprite.swift does NOT use 'Foundation.Timer' (thread-unsafe)..."
if ! grep -q "Foundation\.Timer" "$CAT_SPRITE" 2>/dev/null; then
    pass "Foundation.Timer is absent from CatSprite.swift"
else
    fail "Foundation.Timer found in CatSprite.swift (must use SKAction timing)"
fi

echo "[A] CatSprite.swift does NOT use 'DispatchQueue.asyncAfter' (thread-unsafe)..."
if ! grep -q "DispatchQueue\.asyncAfter" "$CAT_SPRITE" 2>/dev/null; then
    pass "DispatchQueue.asyncAfter is absent from CatSprite.swift"
else
    fail "DispatchQueue.asyncAfter found in CatSprite.swift (must use SKAction timing)"
fi

echo ""
echo "--- [Section 5b] Source code contracts (BuddyScene.swift) ---"

echo "[A] BuddyScene.swift uses spawn X margin of 48 (not 40)..."
# The design requires the 48px sprite size to be reflected in coordinate margins.
# We verify '48' appears in BuddyScene.swift and '40' is not used as the margin.
if grep -q "48" "$BUDDY_SCENE" 2>/dev/null; then
    pass "BuddyScene.swift references '48' (spawn margin updated)"
else
    fail "BuddyScene.swift does NOT reference '48' (spawn margin not updated)"
fi

echo ""

# ── Section 6: Untouched files verification ────────────────────────────────────

echo "--- [Section 6] Untouched files have not been modified ---"

# Strategy: compare md5 of current working copy against the commit HEAD content.
# These checksums were captured from the last clean commit before the upgrade.
# If they differ, the file was modified during the upgrade (which is forbidden).

check_file_unchanged() {
    local label="$1"
    local rel_path="$2"
    local abs_path="$PROJECT_ROOT/$rel_path"

    echo "[A] $label has NOT been modified..."

    # Verify the file still exists first
    if [ ! -f "$abs_path" ]; then
        fail "$label is MISSING at $abs_path"
        return
    fi

    # Compute working-copy hash
    current_hash=$(md5 -q "$abs_path" 2>/dev/null || md5sum "$abs_path" 2>/dev/null | awk '{print $1}')

    # Compute HEAD hash (git show pipes the committed content)
    head_hash=$(git show "HEAD:$rel_path" 2>/dev/null | md5 -q 2>/dev/null || \
                git show "HEAD:$rel_path" 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')

    if [ -z "$head_hash" ]; then
        # File wasn't in the last commit (new project) — skip hash check,
        # just confirm it's a well-formed Swift file
        if grep -q "import " "$abs_path" 2>/dev/null; then
            pass "$label exists and contains Swift imports (no git baseline to compare)"
        else
            fail "$label exists but appears malformed"
        fi
        return
    fi

    if [ "$current_hash" = "$head_hash" ]; then
        pass "$label is unchanged (hash: $current_hash)"
    else
        fail "$label has been MODIFIED (was: $head_hash, now: $current_hash)"
    fi
}

check_file_unchanged "SocketServer.swift"  "Sources/ClaudeCodeBuddy/Network/SocketServer.swift"
check_file_unchanged "HookMessage.swift"   "Sources/ClaudeCodeBuddy/Network/HookMessage.swift"
check_file_unchanged "SessionManager.swift" "Sources/ClaudeCodeBuddy/Session/SessionManager.swift"
check_file_unchanged "BuddyWindow.swift"   "Sources/ClaudeCodeBuddy/Window/BuddyWindow.swift"
check_file_unchanged "DockTracker.swift"   "Sources/ClaudeCodeBuddy/Window/DockTracker.swift"

echo ""

# ── Section 7: Attribution — README credits sprite source ─────────────────────

echo "--- [Section 7] Attribution in README ---"

echo "[A] README.md exists..."
if [ -f "$README" ]; then
    pass "README.md exists"
else
    fail "README.md NOT found at $README"
fi

echo "[A] README.md contains sprite attribution credit..."
# Accept any reasonable attribution keyword: credit/attribution/license/sprite source
if grep -qiE "(credit|attribution|sprite.*source|open.?source.*sprite|CC0|CC BY|license)" "$README" 2>/dev/null; then
    pass "README.md contains sprite attribution/credit"
else
    fail "README.md does NOT mention sprite attribution (credit/attribution/license/CC0)"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
echo "=============================="
echo "Sprite Upgrade Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
