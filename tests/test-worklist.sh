#!/bin/bash
set -euo pipefail

# Modality Worklist (MWL) Test
# Queries the wlmscpfs MWL SCP with `findscu -W` (Modality Worklist Information
# Model) and verifies the scheduled procedure steps built from the fixture
# manifest. Nested Scheduled Procedure Step attributes are matched with the
# DCMTK sequence-key syntax, e.g. -k "0040,0100[0].0008,0060=CT".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
WLM_HOST="${WLM_HOST:-mwl-server}"
WLM_PORT="${WLM_PORT:-11112}"
WLM_AE="${WLM_AE_TITLE:-DCMTK_WLM}"
MY_AE="${AE_TITLE:-TEST_SCU}"

# ── MWL response counting ─────────────────────────────
# Each matched worklist item is one pending C-FIND response; count the
# "Pending" markers from findscu output (NUL-stripped to avoid log noise).
count_mwl_responses() {
    local output="$1"
    printf '%s' "${output}" | tr -d '\0' | grep -c "Pending" || true
}

# Run a worklist query and assert the pending-response count meets the minimum.
# Usage: run_mwl_test "description" expected_min <findscu args...>
run_mwl_test() {
    local description="$1"
    local expected_min="$2"
    shift 2
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local output count
    output=$("$@" 2>&1 | tr -d '\0' || true)
    count=$(count_mwl_responses "${output}")

    if [ "${count}" -ge "${expected_min}" ]; then
        print_pass "MWL: ${description} (found ${count}, expected >= ${expected_min})"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi
    print_fail "MWL: ${description} (found ${count}, expected >= ${expected_min})"
    if [ "${VERBOSE}" = "true" ]; then
        echo "${output}" | tail -10 | while IFS= read -r line; do print_verbose "${line}"; done
    fi
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Preamble: MWL server reachable ────────────────────
ensure_scp_reachable "MWL server" "${WLM_HOST}" "${WLM_PORT}" "${WLM_AE}" "${MY_AE}" || exit 1

print_header "Modality Worklist (MWL) Tests"

# Test 1: universal query returns every scheduled step (one per patient).
run_mwl_test "universal query returns all scheduled steps" "${MANIFEST_STUDY_COUNT}" \
    findscu -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
        -k "0010,0010" -k "0010,0020" -k "0040,0100"

# Test 2: filter by Modality (CT) returns exactly the CT scheduled step.
run_mwl_test "filter by Modality ${MANIFEST_CT_MODALITY}" 1 \
    findscu -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
        -k "0010,0010" -k "0040,0100[0].0008,0060=${MANIFEST_CT_MODALITY}"

# Test 3: filter by Modality (MR) returns the MR scheduled step.
run_mwl_test "filter by Modality ${MANIFEST_MR_MODALITY}" 1 \
    findscu -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
        -k "0010,0010" -k "0040,0100[0].0008,0060=${MANIFEST_MR_MODALITY}"

# Test 4: filter by ScheduledStationAETitle returns all (shared station).
run_mwl_test "filter by ScheduledStationAETitle ${MANIFEST_WLM_STATION_AE}" "${MANIFEST_STUDY_COUNT}" \
    findscu -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
        -k "0010,0010" -k "0040,0100[0].0040,0001=${MANIFEST_WLM_STATION_AE}"

# Test 5: the CT worklist item carries the expected patient identity.
TEST_TOTAL=$((TEST_TOTAL + 1))
CT_OUT=$(findscu -v -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
    -k "0010,0010" -k "0010,0020" \
    -k "0040,0100[0].0008,0060=${MANIFEST_CT_MODALITY}" 2>&1 | tr -d '\0' || true)
if echo "${CT_OUT}" | grep -q "${MANIFEST_CT_PATIENT_ID}"; then
    print_pass "MWL: CT worklist item carries PatientID ${MANIFEST_CT_PATIENT_ID}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "MWL: CT worklist item missing PatientID ${MANIFEST_CT_PATIENT_ID}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 6: negative - a nonexistent modality returns no worklist items.
TEST_TOTAL=$((TEST_TOTAL + 1))
NEG_OUT=$(findscu -W -aet "${MY_AE}" -aec "${WLM_AE}" "${WLM_HOST}" "${WLM_PORT}" \
    -k "0010,0010" -k "0040,0100[0].0008,0060=ZZ" 2>&1 | tr -d '\0' || true)
NEG_COUNT=$(count_mwl_responses "${NEG_OUT}")
if [ "${NEG_COUNT}" -eq 0 ]; then
    print_pass "MWL: nonexistent modality returns 0 worklist items"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "MWL: nonexistent modality returns 0 worklist items (got ${NEG_COUNT})"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# ── Summary ───────────────────────────────────────────
print_summary "MWL"
[ "${TEST_FAILED}" -eq 0 ]
