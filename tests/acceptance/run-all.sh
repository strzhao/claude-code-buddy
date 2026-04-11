#!/bin/bash
# run-all.sh — Master acceptance test runner for Claude Code Buddy.
# Runs every acceptance test script and prints a final summary.
# Exit code 0 = all tests passed; non-zero = at least one test suite failed.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_SUITES=0
FAILED_SUITES=0
PASSED_SUITES=0

# ── Colors (disabled when not a terminal) ─────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

separator() { printf '%s\n' "────────────────────────────────────────────────────────"; }

run_suite() {
    local script="$1"
    local name
    name=$(basename "$script")
    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    separator
    echo -e "${BOLD}Running: $name${RESET}"
    separator

    if bash "$script"; then
        echo -e "${GREEN}SUITE PASSED: $name${RESET}"
        PASSED_SUITES=$((PASSED_SUITES + 1))
    else
        echo -e "${RED}SUITE FAILED: $name${RESET}"
        FAILED_SUITES=$((FAILED_SUITES + 1))
    fi
    echo ""
}

# ── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Claude Code Buddy — Acceptance Test Suite${RESET}"
echo "$(date)"
echo ""

# ── Run suites in dependency order ─────────────────────────────────────────
# 1. Build must pass before socket/bundle tests can run.
# 2. Hook script test is standalone (no running app needed).
# 3. Socket and multi-session tests need the built binary.
# 4. Bundle test needs the bundle script.

run_suite "$SCRIPT_DIR/test-build.sh"
run_suite "$SCRIPT_DIR/test-hook-script.sh"
run_suite "$SCRIPT_DIR/test-session-start.acceptance.test.sh"
run_suite "$SCRIPT_DIR/test-socket-protocol.sh"
run_suite "$SCRIPT_DIR/test-multi-session.sh"
run_suite "$SCRIPT_DIR/test-app-bundle.sh"

# ── Final summary ──────────────────────────────────────────────────────────
separator
echo -e "${BOLD}ACCEPTANCE TEST SUMMARY${RESET}"
separator
echo "  Total suites : $TOTAL_SUITES"
echo -e "  Passed       : ${GREEN}$PASSED_SUITES${RESET}"
if [ "$FAILED_SUITES" -gt 0 ]; then
    echo -e "  Failed       : ${RED}$FAILED_SUITES${RESET}"
else
    echo "  Failed       : $FAILED_SUITES"
fi
separator
echo ""

if [ "$FAILED_SUITES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL ACCEPTANCE TESTS PASSED${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}$FAILED_SUITES SUITE(S) FAILED${RESET}"
    exit 1
fi
