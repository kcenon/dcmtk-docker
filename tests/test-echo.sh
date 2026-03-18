#!/bin/bash
set -euo pipefail

# C-ECHO Connectivity Test
# Tests DICOM verification (C-ECHO) against all SCP services.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration (from environment or defaults) ──────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
PACS2_HOST="${PACS2_HOST:-pacs-server-2}"
PACS2_AE="${PACS2_AE_TITLE:-DCMTK_PAC2}"
STORESCP_HOST="${STORESCP_HOST:-storescp-receiver}"
STORESCP_AE="${STORESCP_AE_TITLE:-STORE_SCP}"
MY_AE="${AE_TITLE:-TEST_SCU}"

# ── Tests ─────────────────────────────────────────────
print_header "C-ECHO Connectivity Tests"

# Test 1: Primary PACS
run_test "pacs-server (${PACS_AE}) connectivity" "C-ECHO" \
    echoscu -aet "${MY_AE}" -aec "${PACS_AE}" "${PACS_HOST}" "${PACS_PORT}" || true

# Test 2: Secondary PACS
run_test "pacs-server-2 (${PACS2_AE}) connectivity" "C-ECHO" \
    echoscu -aet "${MY_AE}" -aec "${PACS2_AE}" "${PACS2_HOST}" "${PACS_PORT}" || true

# Test 3: Store SCP Receiver
run_test "storescp-receiver (${STORESCP_AE}) connectivity" "C-ECHO" \
    echoscu -aet "${MY_AE}" -aec "${STORESCP_AE}" "${STORESCP_HOST}" "${PACS_PORT}" || true

# Test 4: Wrong port (expect failure)
run_test_expect_fail "wrong port (expect failure)" "C-ECHO" \
    echoscu -aet "${MY_AE}" -aec "${PACS_AE}" -to 2 "${PACS_HOST}" 99999 || true

# Test 5: Unreachable host (expect failure)
run_test_expect_fail "unreachable host (expect failure)" "C-ECHO" \
    echoscu -aet "${MY_AE}" -aec "${PACS_AE}" -to 2 nonexistent-host "${PACS_PORT}" || true

# ── Summary ───────────────────────────────────────────
print_summary "C-ECHO"
[ "${TEST_FAILED}" -eq 0 ]
