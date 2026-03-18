#!/bin/bash
set -uo pipefail

# DCMTK PACS Test Suite Runner
# Executes all test scripts in sequence and reports aggregated results.
#
# Usage:
#   docker compose exec test-client /tests/test-all.sh [--verbose]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ───────────────────────────────────
export VERBOSE="${VERBOSE:-false}"
for arg in "$@"; do
    case "${arg}" in
        --verbose|-v) export VERBOSE=true ;;
    esac
done

# ── TTY detection and colors ─────────────────────────
if [ -t 1 ]; then
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_BOLD=''
    C_RESET=''
fi

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_TESTS=0
SUITE_RESULTS=""

# ── Banner ────────────────────────────────────────────
echo ""
printf "${C_BOLD}========================================${C_RESET}\n"
printf "${C_BOLD}  DCMTK PACS Test Suite${C_RESET}\n"
printf "${C_BOLD}========================================${C_RESET}\n"
echo "  PACS:     ${PACS_HOST}:${PACS_PORT} (${PACS_AE})"
echo "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Verbose:  ${VERBOSE}"
printf "${C_BOLD}========================================${C_RESET}\n"
echo ""

# ── Wait for PACS readiness ──────────────────────────
echo "Waiting for PACS services to be ready..."

if [ -x /usr/local/bin/wait-for-pacs.sh ]; then
    /usr/local/bin/wait-for-pacs.sh "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" 30 2
else
    for i in $(seq 1 30); do
        if echoscu -aec "${PACS_AE}" "${PACS_HOST}" "${PACS_PORT}" >/dev/null 2>&1; then
            echo "PACS is ready."
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "ERROR: PACS not ready after 60 seconds. Aborting."
            exit 1
        fi
        sleep 2
    done
fi

echo ""

# ── Run test suites ──────────────────────────────────
run_suite() {
    local name="$1"
    local script="$2"

    if [ ! -f "${script}" ]; then
        printf "${C_RED}[SKIP]${C_RESET} %s: script not found (%s)\n" "${name}" "${script}"
        return
    fi

    local output
    local exit_code=0
    output=$(bash "${script}" 2>&1) || exit_code=$?

    echo "${output}"
    echo ""

    # Count [PASS] and [FAIL] lines directly from test output
    local passed failed total
    passed=$(echo "${output}" | grep -c '^\[PASS\]' || true)
    failed=$(echo "${output}" | grep -c '^\[FAIL\]' || true)
    total=$((passed + failed))

    # Fallback: also count colored PASS/FAIL (ANSI codes before [PASS]/[FAIL])
    if [ "${total}" -eq 0 ]; then
        passed=$(echo "${output}" | grep -c 'PASS' || true)
        failed=$(echo "${output}" | grep -c 'FAIL' || true)
        total=$((passed + failed))
    fi

    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_TESTS=$((TOTAL_TESTS + total))

    if [ "${exit_code}" -eq 0 ]; then
        SUITE_RESULTS="${SUITE_RESULTS}$(printf "  ${C_GREEN}[PASS]${C_RESET} %s: %d/%d passed\n" "${name}" "${passed}" "${total}")\n"
    else
        SUITE_RESULTS="${SUITE_RESULTS}$(printf "  ${C_RED}[FAIL]${C_RESET} %s: %d/%d passed, %d failed\n" "${name}" "${passed}" "${total}" "${failed}")\n"
    fi
}

run_suite "C-ECHO"  "${SCRIPT_DIR}/test-echo.sh"
run_suite "C-STORE" "${SCRIPT_DIR}/test-store.sh"
run_suite "C-FIND"  "${SCRIPT_DIR}/test-find.sh"
run_suite "C-MOVE"  "${SCRIPT_DIR}/test-move.sh"

# ── Final Summary ─────────────────────────────────────
echo ""
printf "${C_BOLD}========================================${C_RESET}\n"
printf "${C_BOLD}  Test Suite Summary${C_RESET}\n"
printf "${C_BOLD}========================================${C_RESET}\n"
echo ""
printf '%b' "${SUITE_RESULTS}"
printf "${C_BOLD}========================================${C_RESET}\n"
printf "  Total: ${C_BOLD}%d/%d${C_RESET} passed" "${TOTAL_PASSED}" "${TOTAL_TESTS}"
if [ "${TOTAL_FAILED}" -gt 0 ]; then
    printf ", ${C_RED}%d failed${C_RESET}" "${TOTAL_FAILED}"
fi
echo ""
printf "${C_BOLD}========================================${C_RESET}\n"
echo ""

if [ "${TOTAL_FAILED}" -gt 0 ]; then
    printf "${C_RED}RESULT: FAILED${C_RESET}\n"
    exit 1
else
    printf "${C_GREEN}RESULT: ALL TESTS PASSED${C_RESET}\n"
    exit 0
fi
