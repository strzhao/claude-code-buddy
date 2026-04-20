#!/bin/bash
# Acceptance Test: swift-snapshot-testing Integration
# Verifies that snapshot tests are wired up correctly:
#   1. Package.swift includes SnapshotTesting dependency and test target
#   2. All 4 expected test source files exist under Tests/BuddyCoreTests/SnapshotTests/
#   3. swift build --build-tests compiles with no errors (SnapshotTesting module resolved)
#   4. First run of swift test --filter Snapshot does NOT crash/abort (baseline-recording
#      failure is acceptable; a clean exit code is not required, just no SIGABRT/crash)
#   5. After first run, __Snapshots__ directories exist and contain .png reference files
#   6. Second run of swift test --filter Snapshot PASSES (baselines now exist)
#   7. Full swift test suite still passes with no regressions

set -o pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SNAPSHOT_TEST_DIR="$PROJECT_ROOT/Tests/BuddyCoreTests/SnapshotTests"
PACKAGE_SWIFT="$PROJECT_ROOT/Package.swift"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Test: swift-snapshot-testing Integration ==="
echo "Project root:      $PROJECT_ROOT"
echo "Snapshot test dir: $SNAPSHOT_TEST_DIR"
echo ""

# ── Section 1: Package.swift declarations ─────────────────────────────────────

echo "--- [Section 1] Package.swift declarations ---"

echo "[1a] Package.swift exists..."
if [ -f "$PACKAGE_SWIFT" ]; then
    pass "Package.swift found"
else
    fail "Package.swift NOT found at $PACKAGE_SWIFT"
fi

echo "[1b] Package.swift declares swift-snapshot-testing dependency..."
if grep -q "swift-snapshot-testing\|SnapshotTesting" "$PACKAGE_SWIFT" 2>/dev/null; then
    pass "Package.swift references swift-snapshot-testing / SnapshotTesting"
else
    fail "Package.swift does NOT reference swift-snapshot-testing"
fi

echo "[1c] Package.swift test target includes SnapshotTesting dependency..."
# The test target block must mention SnapshotTesting in its dependencies list
if grep -A 20 "BuddyCoreTests\|testTarget" "$PACKAGE_SWIFT" 2>/dev/null | grep -q "SnapshotTesting"; then
    pass "BuddyCoreTests target lists SnapshotTesting as a dependency"
else
    fail "BuddyCoreTests target does NOT list SnapshotTesting (check Package.swift)"
fi

echo ""

# ── Section 2: Test source files exist ────────────────────────────────────────

echo "--- [Section 2] Snapshot test source files ---"

EXPECTED_FILES=(
    "SnapshotTestHelpers.swift"
    "SkinCardSnapshotTests.swift"
    "SkinGallerySnapshotTests.swift"
    "CatSpriteSnapshotTests.swift"
)

for fname in "${EXPECTED_FILES[@]}"; do
    fpath="$SNAPSHOT_TEST_DIR/$fname"
    echo "[2] $fname exists..."
    if [ -f "$fpath" ]; then
        pass "$fname found at Tests/BuddyCoreTests/SnapshotTests/$fname"
    else
        fail "$fname NOT found at $fpath"
    fi
done

echo ""

# ── Section 3: Compilation ─────────────────────────────────────────────────────

echo "--- [Section 3] Compilation with SnapshotTesting module ---"

echo "[3] swift build --build-tests succeeds..."
cd "$PROJECT_ROOT"
BUILD_OUTPUT=$(swift build --build-tests 2>&1)
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
    pass "swift build --build-tests exits 0 (SnapshotTesting module resolved)"
else
    fail "swift build --build-tests FAILED (exit $BUILD_EXIT)"
    echo "--- build output (last 30 lines) ---"
    echo "$BUILD_OUTPUT" | tail -30
    echo "--- end build output ---"
    echo ""
    echo "Cannot continue without a successful build."
    echo ""
    echo "--- Snapshot Testing Test Results: $PASS passed, $FAIL failed ---"
    exit 1
fi

echo ""

# ── Section 4: First run — no crash, just baseline recording failures ──────────

echo "--- [Section 4] First run (baseline recording) ---"

echo "[4] swift test --filter Snapshot runs without crash/abort (first run)..."
# On first run, swift-snapshot-testing RECORDs new baselines and the tests fail
# with a descriptive message.  That is the designed behaviour.
# We accept any clean exit (0 = already have baselines, non-zero = recording) as
# long as the process is not killed by a signal (SIGABRT, SIGSEGV, etc.).
FIRST_RUN_OUTPUT=$(swift test --filter Snapshot 2>&1)
FIRST_RUN_EXIT=$?

# A signal-killed process exits with code > 128 on macOS (128 + signal number).
# SIGABRT = 6, so 134; SIGSEGV = 11, so 139; etc.
# We consider exit codes 0–127 acceptable (success or test-failure, not a crash).
if [ $FIRST_RUN_EXIT -lt 128 ]; then
    pass "First run exited cleanly (exit $FIRST_RUN_EXIT) — no crash or abort"
else
    fail "First run exit code $FIRST_RUN_EXIT suggests a signal/crash (expected < 128)"
    echo "--- first run output (last 40 lines) ---"
    echo "$FIRST_RUN_OUTPUT" | tail -40
    echo "--- end first run output ---"
fi

echo ""

# ── Section 5: __Snapshots__ directories and .png files ───────────────────────

echo "--- [Section 5] Snapshot reference files recorded ---"

# swift-snapshot-testing writes reference images next to the test source file:
#   Tests/BuddyCoreTests/SnapshotTests/__Snapshots__/<TestClassName>/testName.png
# OR at the top-level Tests/BuddyCoreTests/__Snapshots__/ depending on config.
# We search both locations.

echo "[5a] At least one __Snapshots__ directory exists after first run..."
SNAP_DIRS=$(find "$PROJECT_ROOT/Tests" -type d -name "__Snapshots__" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SNAP_DIRS" -gt 0 ]; then
    pass "Found $SNAP_DIRS __Snapshots__ director(y/ies) under Tests/"
    find "$PROJECT_ROOT/Tests" -type d -name "__Snapshots__" 2>/dev/null | while read -r d; do
        echo "        $d"
    done
else
    fail "No __Snapshots__ directories found under Tests/ after first run"
fi

echo "[5b] At least one .png snapshot file was recorded..."
PNG_COUNT=$(find "$PROJECT_ROOT/Tests" -path "*__Snapshots__*" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PNG_COUNT" -gt 0 ]; then
    pass "Found $PNG_COUNT .png snapshot file(s) under __Snapshots__"
else
    fail "No .png files found under __Snapshots__ — baselines were not recorded"
fi

echo "[5c] Snapshots exist for each expected test class..."
EXPECTED_CLASSES=(
    "SkinCardSnapshotTests"
    "SkinGallerySnapshotTests"
    "CatSpriteSnapshotTests"
)
for cls in "${EXPECTED_CLASSES[@]}"; do
    cls_pngs=$(find "$PROJECT_ROOT/Tests" -path "*__Snapshots__*" -name "*.png" 2>/dev/null | grep -i "$cls" | wc -l | tr -d ' ')
    echo "[5c] $cls has at least one snapshot..."
    if [ "$cls_pngs" -gt 0 ]; then
        pass "$cls: found $cls_pngs snapshot(s)"
    else
        # Snapshots may be grouped by test-method name rather than class directory.
        # Fall back: any png in any Snapshots dir whose path mentions the class.
        fallback=$(find "$PROJECT_ROOT/Tests" -path "*__Snapshots__*" 2>/dev/null | grep -i "$cls" | wc -l | tr -d ' ')
        if [ "$fallback" -gt 0 ]; then
            pass "$cls: found snapshot reference (non-png path match)"
        else
            fail "$cls: no snapshots found under __Snapshots__"
        fi
    fi
done

echo ""

# ── Section 6: Second run — all snapshot tests must PASS ──────────────────────

echo "--- [Section 6] Second run (baselines exist — tests must PASS) ---"

echo "[6] swift test --filter Snapshot passes on second run..."
SECOND_RUN_OUTPUT=$(swift test --filter Snapshot 2>&1)
SECOND_RUN_EXIT=$?
if [ $SECOND_RUN_EXIT -eq 0 ]; then
    pass "Second run exits 0 — all snapshot tests pass against recorded baselines"
else
    fail "Second run FAILED (exit $SECOND_RUN_EXIT) — snapshot tests did not stabilise"
    echo "--- second run output (last 50 lines) ---"
    echo "$SECOND_RUN_OUTPUT" | tail -50
    echo "--- end second run output ---"
fi

echo ""

# ── Section 7: No regression — full test suite ────────────────────────────────

echo "--- [Section 7] No regression in full test suite ---"

echo "[7] swift test (full suite) passes..."
FULL_OUTPUT=$(swift test 2>&1)
FULL_EXIT=$?
if [ $FULL_EXIT -eq 0 ]; then
    pass "Full swift test suite exits 0 — no regressions introduced"
else
    fail "Full swift test suite FAILED (exit $FULL_EXIT)"
    echo "--- full test output (last 50 lines) ---"
    echo "$FULL_OUTPUT" | tail -50
    echo "--- end full test output ---"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────

echo "=============================="
echo "Snapshot Testing Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
