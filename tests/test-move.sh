#!/bin/bash
set -euo pipefail

# C-MOVE Retrieval Test
# Tests retrieving images from PACS to the storescp-receiver destination.
#
# C-MOVE flow:
#   test-client (SCU) --C-MOVE request--> pacs-server (SCP)
#                                            |
#                                            +--C-STORE--> storescp-receiver (destination)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
STORESCP_HOST="${STORESCP_HOST:-storescp-receiver}"
STORESCP_AE="${STORESCP_AE_TITLE:-STORE_SCP}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
OID_ROOT="${OID_ROOT:-1.2.826.0.1.3680043.8.1055}"

# ── Preamble: verify required SCPs are reachable ──────
# Both the source PACS and the storescp-receiver destination must be up
# before any C-MOVE work. Fail fast with a clear message if either is
# missing, so this script can be invoked standalone in any order.
ensure_scp_reachable "source PACS"        "${PACS_HOST}"     "${PACS_PORT}" "${PACS_AE}"     "${MY_AE}" || exit 1
ensure_scp_reachable "storescp-receiver"  "${STORESCP_HOST}" "${PACS_PORT}" "${STORESCP_AE}" "${MY_AE}" || exit 1

# ── Ensure PACS has data ──────────────────────────────
ensure_pacs_data "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" "${TEST_DATA_DIR}"

print_header "C-MOVE Retrieval Tests"

# ── Prerequisite: storescp-receiver reachable ─────────
TEST_TOTAL=$((TEST_TOTAL + 1))
if echoscu -aet "${MY_AE}" -aec "${STORESCP_AE}" "${STORESCP_HOST}" "${PACS_PORT}" >/dev/null 2>&1; then
    print_pass "C-MOVE: prerequisite - storescp-receiver is reachable"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "C-MOVE: prerequisite - storescp-receiver is NOT reachable"
    echo "       C-MOVE tests require storescp-receiver to be running."
    TEST_FAILED=$((TEST_FAILED + 1))
    print_summary "C-MOVE"
    exit 1
fi

# ── Test 1: C-MOVE CT study (PAT001, 5 instances) ────
CT_STUDY_UID="${OID_ROOT}.1.1"
run_test "retrieve CT study PAT001 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${CT_STUDY_UID}" || true
sleep 2

# ── Test 2: C-MOVE MR study (PAT002, 6 instances) ────
MR_STUDY_UID="${OID_ROOT}.2.1"
run_test "retrieve MR study PAT002 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${MR_STUDY_UID}" || true
sleep 2

# ── Test 3: C-MOVE CR study (PAT003, 2 instances) ────
CR_STUDY_UID="${OID_ROOT}.3.1"
run_test "retrieve CR study PAT003 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${CR_STUDY_UID}" || true
sleep 2

# ── Test 4: C-MOVE nonexistent study (graceful) ──────
TEST_TOTAL=$((TEST_TOTAL + 1))
MOVE_OUTPUT=$(movescu -v -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
    -S "${PACS_HOST}" "${PACS_PORT}" \
    -k QueryRetrieveLevel=STUDY \
    -k StudyInstanceUID="1.2.3.999.999.999" 2>&1 || true)

if echo "${MOVE_OUTPUT}" | grep -qi "error\|refused\|abort" 2>/dev/null; then
    print_fail "C-MOVE: nonexistent study (unexpected error)"
    TEST_FAILED=$((TEST_FAILED + 1))
else
    print_pass "C-MOVE: nonexistent study handled gracefully"
    TEST_PASSED=$((TEST_PASSED + 1))
fi

# ── Test 5: C-MOVE at SERIES level ───────────────────
# Retrieve only the T1 series from PAT002's MR study
T1_SERIES_UID="${OID_ROOT}.2.1.1"
run_test "retrieve MR T1 series (SERIES level) to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=SERIES \
        -k StudyInstanceUID="${MR_STUDY_UID}" \
        -k SeriesInstanceUID="${T1_SERIES_UID}" || true
sleep 1

# ── Test 6: Receiver health after transfers ───────────
TEST_TOTAL=$((TEST_TOTAL + 1))
if echoscu -aet "${MY_AE}" -aec "${STORESCP_AE}" "${STORESCP_HOST}" "${PACS_PORT}" >/dev/null 2>&1; then
    print_pass "C-MOVE: storescp-receiver still healthy after transfers"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "C-MOVE: storescp-receiver unhealthy after transfers"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# ── Summary ───────────────────────────────────────────
print_summary "C-MOVE"
[ "${TEST_FAILED}" -eq 0 ]
