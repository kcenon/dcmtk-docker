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
OID_ROOT="${OID_ROOT:-${DEFAULT_OID_ROOT}}"
RECEIVER_STORAGE_DIR="$(receiver_storage_dir)"
# Settle window for storescp to flush incoming instances to disk before
# we count them. Keep small to avoid inflating wall-clock time when the
# whole suite runs.
MOVE_SETTLE_SECONDS="${MOVE_SETTLE_SECONDS:-2}"
print_verbose "OID_ROOT=${OID_ROOT}"
print_verbose "RECEIVER_STORAGE_DIR=${RECEIVER_STORAGE_DIR}"

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

# ── Receiver storage cleanup (precondition) ───────────
# Wipe any instances left behind by a previous suite run so the per-case
# count and UID checks below reflect what THIS test actually retrieved.
# See issue #33.
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}" || exit 1

# ── Test 1: C-MOVE CT study (PAT001, 5 instances) ────
CT_STUDY_UID="${OID_ROOT}.1.1"
CT_EXPECTED=5
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}"
run_test "retrieve CT study PAT001 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${CT_STUDY_UID}" || true
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "CT study PAT001 instance count" "${CT_EXPECTED}" "${RECEIVER_STORAGE_DIR}" || true
verify_move_uids  "CT study PAT001 UIDs"           "${CT_STUDY_UID}" "" "${RECEIVER_STORAGE_DIR}" || true

# ── Test 2: C-MOVE MR study (PAT002, 6 instances) ────
MR_STUDY_UID="${OID_ROOT}.2.1"
MR_EXPECTED=6
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}"
run_test "retrieve MR study PAT002 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${MR_STUDY_UID}" || true
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "MR study PAT002 instance count" "${MR_EXPECTED}" "${RECEIVER_STORAGE_DIR}" || true
verify_move_uids  "MR study PAT002 UIDs"           "${MR_STUDY_UID}" "" "${RECEIVER_STORAGE_DIR}" || true

# ── Test 3: C-MOVE CR study (PAT003, 2 instances) ────
CR_STUDY_UID="${OID_ROOT}.3.1"
CR_EXPECTED=2
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}"
run_test "retrieve CR study PAT003 to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${CR_STUDY_UID}" || true
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "CR study PAT003 instance count" "${CR_EXPECTED}" "${RECEIVER_STORAGE_DIR}" || true
verify_move_uids  "CR study PAT003 UIDs"           "${CR_STUDY_UID}" "" "${RECEIVER_STORAGE_DIR}" || true

# ── Test 4: C-MOVE nonexistent study (graceful) ──────
# Nonexistent retrievals must not leave anything on the receiver. Clean
# first so the count check below isolates this case.
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}"
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
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "nonexistent study leaves receiver empty" 0 "${RECEIVER_STORAGE_DIR}" || true

# ── Test 5: C-MOVE at SERIES level ───────────────────
# Retrieve only the T1 series from PAT002's MR study (3 instances).
T1_SERIES_UID="${OID_ROOT}.2.1.1"
T1_EXPECTED=3
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}"
run_test "retrieve MR T1 series (SERIES level) to ${STORESCP_AE}" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=SERIES \
        -k StudyInstanceUID="${MR_STUDY_UID}" \
        -k SeriesInstanceUID="${T1_SERIES_UID}" || true
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "MR T1 series instance count"  "${T1_EXPECTED}"     "${RECEIVER_STORAGE_DIR}" || true
verify_move_uids  "MR T1 series UIDs"            "${MR_STUDY_UID}"    "${T1_SERIES_UID}" "${RECEIVER_STORAGE_DIR}" || true

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
