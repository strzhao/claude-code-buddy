#!/usr/bin/env bash
# Acceptance Test: Popover Cell Layout Optimization
# Verifies that the menu bar popover list cell layout meets the design spec:
#   - Cell rows are left-aligned with explicit width constraints
#   - Popover height is 450pt to display ~6 rows
#   - Long CWD paths are truncated intelligently to ~/…/<last-dir>
#
# These are static source-code checks — no app launch required.

set -euo pipefail

PASS=0
FAIL=0

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POPOVER_CTRL="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift"
APPDELEGATE="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/App/AppDelegate.swift"
ROW_VIEW="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Popover Cell Layout Optimization ==="
echo "PopoverController: $POPOVER_CTRL"
echo "AppDelegate:       $APPDELEGATE"
echo "SessionRowView:    $ROW_VIEW"
echo ""

# ── Assertion 1: swift build (hard stop on failure) ───────────────────────
echo "[1] swift build (debug) succeeds..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0"
else
    fail "swift build failed — cannot continue"
    echo "--- Popover Cell Layout Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi
echo ""

# ── Assertion 2: container frame height is 450pt ─────────────────────────
echo "[2] SessionPopoverController.swift — container frame height is 450..."
if grep -q "height: 450" "$POPOVER_CTRL"; then
    pass "container frame contains 'height: 450'"
else
    fail "container frame does NOT contain 'height: 450' in $POPOVER_CTRL"
fi

# ── Assertion 3: popover contentSize height is 450pt ─────────────────────
echo "[3] AppDelegate.swift — popover.contentSize height is 450..."
if grep -q "height: 450" "$APPDELEGATE"; then
    pass "popover.contentSize contains 'height: 450'"
else
    fail "popover.contentSize does NOT contain 'height: 450' in $APPDELEGATE"
fi

# ── Assertion 4: updateSessions sets row width anchor ────────────────────
echo "[4] SessionPopoverController.swift — updateSessions sets widthAnchor.constraint(equalTo: stackView.widthAnchor)..."
if grep -q "widthAnchor.constraint(equalTo: stackView.widthAnchor)" "$POPOVER_CTRL"; then
    pass "updateSessions contains row widthAnchor constraint to stackView"
else
    fail "updateSessions does NOT contain 'widthAnchor.constraint(equalTo: stackView.widthAnchor)' in $POPOVER_CTRL"
fi

# ── Assertion 5: CWD lineBreakMode is .byTruncatingTail ──────────────────
echo "[5] SessionRowView.swift — CWD field lineBreakMode is .byTruncatingTail (not .byTruncatingMiddle)..."
if grep -q "lineBreakMode = .byTruncatingTail" "$ROW_VIEW"; then
    pass "CWD lineBreakMode set to .byTruncatingTail"
else
    fail "CWD lineBreakMode is NOT .byTruncatingTail in $ROW_VIEW"
fi

# ── Assertion 6: path abbreviation logic exists ───────────────────────────
echo "[6] SessionRowView.swift — contains path abbreviation logic (components.count > 3 or similar)..."
if grep -qE "components\.count\s*[><=!]=?\s*[0-9]|components\[|split\(separator:.*\"/\"|pathComponents" "$ROW_VIEW"; then
    pass "Path abbreviation logic found in SessionRowView.swift"
else
    fail "No path abbreviation logic found in $ROW_VIEW (expected 'components.count > 3' or similar)"
fi

# ── Assertion 7: no .center alignment on row cells ────────────────────────
echo "[7] SessionRowView.swift — does NOT contain 'alignment = .center' (rows must be left-aligned)..."
if grep -q "alignment = .center" "$ROW_VIEW"; then
    fail "SessionRowView.swift contains 'alignment = .center' — rows should NOT be center-aligned"
else
    pass "No 'alignment = .center' found in SessionRowView.swift"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "--- Popover Cell Layout Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
