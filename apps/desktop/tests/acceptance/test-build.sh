#!/bin/bash
# Acceptance Test: Build Verification
# Verifies that the Swift package builds successfully in both debug and release modes.
# Based on design spec: Technical Stack — Swift, macOS desktop app.

set -e

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: Build Verification ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# ── Assertion 1: swift build (debug) exits with code 0 ─────────────────────
echo "[1] swift build (debug) succeeds..."
cd "$PROJECT_ROOT"
if swift build 2>&1; then
    pass "swift build exits 0"
else
    fail "swift build failed (non-zero exit)"
fi

# ── Assertion 2: debug executable exists ───────────────────────────────────
echo "[2] Debug executable exists..."
DEBUG_BIN="$PROJECT_ROOT/.build/debug/ClaudeCodeBuddy"
if [ -f "$DEBUG_BIN" ]; then
    pass "Debug executable exists at .build/debug/ClaudeCodeBuddy"
else
    fail "Debug executable NOT found at $DEBUG_BIN"
fi

# ── Assertion 3: swift build -c release exits with code 0 ──────────────────
echo "[3] swift build -c release succeeds..."
if swift build -c release 2>&1; then
    pass "swift build -c release exits 0"
else
    fail "swift build -c release failed (non-zero exit)"
fi

# ── Assertion 4: release executable exists ─────────────────────────────────
echo "[4] Release executable exists..."
RELEASE_BIN="$PROJECT_ROOT/.build/release/ClaudeCodeBuddy"
if [ -f "$RELEASE_BIN" ]; then
    pass "Release executable exists at .build/release/ClaudeCodeBuddy"
else
    fail "Release executable NOT found at $RELEASE_BIN"
fi

# ── Assertion 5: debug executable is a Mach-O binary ──────────────────────
echo "[5] Debug executable is a valid Mach-O binary..."
if [ -f "$DEBUG_BIN" ] && file "$DEBUG_BIN" | grep -q "Mach-O"; then
    pass "Debug executable is Mach-O"
else
    fail "Debug executable is not a valid Mach-O binary (or does not exist)"
fi

# ── Assertion 6: release executable is a Mach-O binary ───────────────────
echo "[6] Release executable is a valid Mach-O binary..."
if [ -f "$RELEASE_BIN" ] && file "$RELEASE_BIN" | grep -q "Mach-O"; then
    pass "Release executable is Mach-O"
else
    fail "Release executable is not a valid Mach-O binary (or does not exist)"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- Build Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
