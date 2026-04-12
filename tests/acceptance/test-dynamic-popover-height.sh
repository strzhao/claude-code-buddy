#!/usr/bin/env bash
# Acceptance Test: Dynamic Popover Height
# Verifies that the menu bar popover height adapts dynamically to session count:
#   - No hardcoded height: 450 in SessionPopoverController.swift
#   - No hardcoded popover.contentSize in AppDelegate.swift
#   - idealHeight(for:) method exists in SessionPopoverController.swift
#   - maxVisibleSessions = 6 constant exists
#   - emptyStateHeight constant exists
#   - preferredContentSize is set in both updateSessions and loadView
#
# These are static source-code checks — no app launch required.

set -euo pipefail

PASS=0
FAIL=0

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POPOVER_CTRL="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift"
APPDELEGATE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/App/AppDelegate.swift"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Dynamic Popover Height ==="
echo "PopoverController: $POPOVER_CTRL"
echo "AppDelegate:       $APPDELEGATE"
echo ""

# ── Assertion 1: SessionPopoverController does NOT hardcode height: 450 ──────
echo "[1] SessionPopoverController.swift — does NOT contain hardcoded 'height: 450'..."
if grep -q "height: 450" "$POPOVER_CTRL"; then
    fail "SessionPopoverController.swift still contains hardcoded 'height: 450' — should use dynamic height"
else
    pass "No hardcoded 'height: 450' in SessionPopoverController.swift"
fi

# ── Assertion 2: AppDelegate does NOT hardcode popover.contentSize ────────────
echo "[2] AppDelegate.swift — does NOT contain hardcoded 'popover.contentSize'..."
if grep -q "popover\.contentSize" "$APPDELEGATE"; then
    fail "AppDelegate.swift still contains hardcoded 'popover.contentSize' — should be removed"
else
    pass "No hardcoded 'popover.contentSize' in AppDelegate.swift"
fi

# ── Assertion 3: idealHeight(for:) method exists ──────────────────────────────
echo "[3] SessionPopoverController.swift — contains 'idealHeight' method..."
if grep -qE "func idealHeight\(for" "$POPOVER_CTRL"; then
    pass "idealHeight(for:) method found in SessionPopoverController.swift"
else
    fail "idealHeight(for:) method NOT found in $POPOVER_CTRL"
fi

# ── Assertion 4: maxVisibleSessions = 6 constant exists ───────────────────────
echo "[4] SessionPopoverController.swift — contains 'maxVisibleSessions = 6' constant..."
if grep -qE "maxVisibleSessions\s*=\s*6" "$POPOVER_CTRL"; then
    pass "maxVisibleSessions = 6 found in SessionPopoverController.swift"
else
    fail "maxVisibleSessions = 6 NOT found in $POPOVER_CTRL"
fi

# ── Assertion 5: emptyStateHeight constant exists ─────────────────────────────
echo "[5] SessionPopoverController.swift — contains 'emptyStateHeight' constant..."
if grep -qE "emptyStateHeight" "$POPOVER_CTRL"; then
    pass "emptyStateHeight constant found in SessionPopoverController.swift"
else
    fail "emptyStateHeight constant NOT found in $POPOVER_CTRL"
fi

# ── Assertion 6: preferredContentSize set in updateSessions ───────────────────
echo "[6] SessionPopoverController.swift — preferredContentSize is set inside updateSessions..."
# Extract the body of updateSessions and check for preferredContentSize
if grep -qE "preferredContentSize" "$POPOVER_CTRL"; then
    # Verify it appears in the context of updateSessions (within the file, order-sensitive check)
    if awk '/func updateSessions/,/^    \}/' "$POPOVER_CTRL" | grep -q "preferredContentSize"; then
        pass "preferredContentSize is set inside updateSessions"
    else
        fail "preferredContentSize found in file but NOT inside updateSessions in $POPOVER_CTRL"
    fi
else
    fail "preferredContentSize NOT found anywhere in $POPOVER_CTRL"
fi

# ── Assertion 7: preferredContentSize set in loadView ─────────────────────────
echo "[7] SessionPopoverController.swift — preferredContentSize is set inside loadView..."
if awk '/func loadView/,/^    \}/' "$POPOVER_CTRL" | grep -q "preferredContentSize"; then
    pass "preferredContentSize is set inside loadView"
else
    fail "preferredContentSize NOT found inside loadView in $POPOVER_CTRL"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Dynamic Popover Height Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
