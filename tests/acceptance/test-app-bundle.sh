#!/bin/bash
# Acceptance Test: App Bundle Structure
# Verifies that the bundle script produces a correctly-structured .app bundle
# matching the macOS conventions required by the design spec.
# Design spec references: LSUIElement=true (menu bar app), executable name
# ClaudeCodeBuddy, transparent floating window.

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_SCRIPT="$PROJECT_ROOT/scripts/bundle.sh"
APP_BUNDLE="$PROJECT_ROOT/ClaudeCodeBuddy.app"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    # Remove bundle created during this test (leave any pre-existing one alone)
    if [ -n "$CREATED_BUNDLE" ] && [ -d "$APP_BUNDLE" ]; then
        rm -rf "$APP_BUNDLE"
    fi
}
trap cleanup EXIT

echo "=== Test: App Bundle Structure ==="
echo "Project root:  $PROJECT_ROOT"
echo "Bundle script: $BUNDLE_SCRIPT"
echo "App bundle:    $APP_BUNDLE"
echo ""

# ── Assertion 1: bundle script exists ─────────────────────────────────────
echo "[1] scripts/bundle.sh exists..."
if [ -f "$BUNDLE_SCRIPT" ]; then
    pass "scripts/bundle.sh exists"
else
    fail "scripts/bundle.sh NOT found at $BUNDLE_SCRIPT"
    # Attempt a fallback: look for any bundle/package script
    BUNDLE_SCRIPT=$(find "$PROJECT_ROOT" -maxdepth 3 -name "bundle*.sh" 2>/dev/null | head -1)
    if [ -n "$BUNDLE_SCRIPT" ]; then
        echo "    Found alternative script: $BUNDLE_SCRIPT"
    fi
fi

# ── Assertion 2: bundle script is executable ──────────────────────────────
echo "[2] Bundle script is executable..."
if [ -f "$BUNDLE_SCRIPT" ] && [ -x "$BUNDLE_SCRIPT" ]; then
    pass "Bundle script is executable"
else
    fail "Bundle script is NOT executable (or does not exist)"
fi

# ── Run the bundle script ──────────────────────────────────────────────────
if [ -f "$BUNDLE_SCRIPT" ]; then
    echo "[setup] Running bundle script..."
    # Remove any stale bundle first
    [ -d "$APP_BUNDLE" ] && rm -rf "$APP_BUNDLE"
    CREATED_BUNDLE=1

    if ! bash "$BUNDLE_SCRIPT" 2>&1; then
        fail "Bundle script exited with non-zero code"
        echo "    Cannot verify bundle structure without a successful build."
        echo ""
        echo "--- Bundle Test Results: $PASS passed, $FAIL failed ---"
        exit 1
    fi
    pass "Bundle script completed successfully"
else
    echo "  SKIP: No bundle script found — checking for pre-built bundle..."
fi

# ── Assertion 3: .app bundle directory exists ─────────────────────────────
echo "[3] .app bundle directory exists..."
if [ -d "$APP_BUNDLE" ]; then
    pass ".app bundle exists at $APP_BUNDLE"
else
    fail ".app bundle NOT found at $APP_BUNDLE"
    echo "    Remaining assertions require the bundle — stopping."
    echo ""
    echo "--- Bundle Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi

# ── Assertion 4: Contents/MacOS/ directory exists ─────────────────────────
echo "[4] Contents/MacOS/ directory exists..."
if [ -d "$APP_BUNDLE/Contents/MacOS" ]; then
    pass "Contents/MacOS/ directory exists"
else
    fail "Contents/MacOS/ directory NOT found"
fi

# ── Assertion 5: Executable exists inside Contents/MacOS/ ─────────────────
echo "[5] ClaudeCodeBuddy executable exists at Contents/MacOS/ClaudeCodeBuddy..."
EXEC_PATH="$APP_BUNDLE/Contents/MacOS/ClaudeCodeBuddy"
if [ -f "$EXEC_PATH" ]; then
    pass "Contents/MacOS/ClaudeCodeBuddy exists"
else
    fail "Contents/MacOS/ClaudeCodeBuddy NOT found"
fi

# ── Assertion 6: Executable is a Mach-O binary ────────────────────────────
echo "[6] Executable is a valid Mach-O binary..."
if [ -f "$EXEC_PATH" ] && file "$EXEC_PATH" | grep -q "Mach-O"; then
    pass "Executable is Mach-O"
else
    fail "Executable is not a valid Mach-O binary (or does not exist)"
fi

# ── Assertion 7: Executable has execute permission ────────────────────────
echo "[7] Executable has execute permission..."
if [ -x "$EXEC_PATH" ]; then
    pass "Executable is runnable (has +x)"
else
    fail "Executable does NOT have execute permission"
fi

# ── Assertion 8: Info.plist exists ────────────────────────────────────────
echo "[8] Contents/Info.plist exists..."
PLIST="$APP_BUNDLE/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    pass "Contents/Info.plist exists"
else
    fail "Contents/Info.plist NOT found"
fi

# ── Assertion 9: LSUIElement = true (menu bar / agent app) ───────────────
# Design spec: "Menu bar icon (with quit option)" → LSUIElement must be true.
echo "[9] Info.plist contains LSUIElement=true..."
if [ -f "$PLIST" ]; then
    # plutil is available on macOS; fall back to grep for CI environments
    lsui=$(plutil -extract LSUIElement raw "$PLIST" 2>/dev/null || true)
    if [ "$lsui" = "1" ] || [ "$lsui" = "true" ]; then
        pass "LSUIElement=true found in Info.plist"
    elif grep -q "LSUIElement" "$PLIST" 2>/dev/null; then
        # Found the key — check the value more loosely
        if grep -A1 "LSUIElement" "$PLIST" | grep -qE "true|<true/>|1"; then
            pass "LSUIElement=true found in Info.plist (via grep)"
        else
            fail "LSUIElement key found but value is not true"
        fi
    else
        fail "LSUIElement key NOT found in Info.plist"
    fi
else
    fail "Cannot check LSUIElement — Info.plist does not exist"
fi

# ── Assertion 10: Info.plist has a CFBundleName or CFBundleExecutable ─────
echo "[10] Info.plist contains CFBundleExecutable=ClaudeCodeBuddy..."
if [ -f "$PLIST" ]; then
    bundle_exec=$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null || grep -A1 "CFBundleExecutable" "$PLIST" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    if echo "$bundle_exec" | grep -q "ClaudeCodeBuddy"; then
        pass "CFBundleExecutable=ClaudeCodeBuddy in Info.plist"
    else
        fail "CFBundleExecutable does not match 'ClaudeCodeBuddy' (got: '$bundle_exec')"
    fi
else
    fail "Cannot check CFBundleExecutable — Info.plist does not exist"
fi

# ── Assertion 11: Contents/Resources/ directory exists ───────────────────
echo "[11] Contents/Resources/ directory exists..."
if [ -d "$APP_BUNDLE/Contents/Resources" ]; then
    pass "Contents/Resources/ directory exists"
else
    fail "Contents/Resources/ directory NOT found"
fi

# ── Assertion 12: Executable can be invoked (--help or short run) ────────
echo "[12] Executable can be launched (exits or runs without immediate crash)..."
if [ -x "$EXEC_PATH" ]; then
    # Launch for 1 second then kill; a non-zero exit from kill is expected
    "$EXEC_PATH" &
    TEST_PID=$!
    sleep 1
    if kill -0 "$TEST_PID" 2>/dev/null; then
        kill "$TEST_PID" 2>/dev/null
        wait "$TEST_PID" 2>/dev/null || true
        pass "Executable ran for 1 s without crashing"
    else
        # Already exited — check if it was a clean exit
        wait "$TEST_PID" 2>/dev/null
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            pass "Executable started and exited cleanly"
        else
            fail "Executable crashed immediately (exit code $exit_code)"
        fi
    fi
else
    fail "Cannot launch — executable missing or not runnable"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "--- App Bundle Test Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
