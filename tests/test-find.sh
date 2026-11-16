#!/bin/bash
set -euo pipefail

# C-FIND Query Test
# Tests querying the PACS at STUDY, SERIES levels with various filters.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
OID_ROOT="${OID_ROOT:-${DEFAULT_OID_ROOT}}"
print_verbose "OID_ROOT=${OID_ROOT}"

# ── C-FIND test runner ────────────────────────────────
# Runs findscu and compares the number of matches with the expectation.
# Usage: run_find_test "description" min|exact <count> <findscu command...>
#   min   - at least <count> matches (other suites may add studies)
#   exact - exactly <count> matches
run_find_test() {
    local description="$1"
    local mode="$2"
    local expected="$3"
    shift 3
    TEST_TOTAL=$((TEST_TOTAL + 1))

    # Capture findscu output stripped of NUL bytes so `ignored null byte`
    # warnings from shell variable assignment do not appear in test logs.
    local output
    output=$("$@" 2>&1 | tr -d '\0' || true)

    # Count pending C-FIND responses (one per match). See
    # count_find_responses in test-helpers.sh.
    local match_count
    match_count=$(count_find_responses "${output}")

    local ok=false expectation
    case "${mode}" in
        min)
            expectation="expected >= ${expected}"
            [ "${match_count}" -ge "${expected}" ] && ok=true
            ;;
        exact)
            expectation="expected ${expected}"
            [ "${match_count}" -eq "${expected}" ] && ok=true
            ;;
        *)
            expectation="unknown comparison mode '${mode}'"
            ;;
    esac

    if [ "${ok}" = true ]; then
        print_pass "C-FIND: ${description} (found ${match_count}, ${expectation})"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    else
        print_fail "C-FIND: ${description} (found ${match_count}, ${expectation})"
        if [ "${VERBOSE}" = "true" ]; then
            echo "${output}" | tail -10 | while IFS= read -r line; do
                print_verbose "${line}"
            done
        fi
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi
}

# ── Preamble: verify required SCPs are reachable ──────
# Make the precondition explicit so this script can be invoked in any
# order. ensure_pacs_data() is called below, but the C-ECHO check fails
# fast with an actionable message when the PACS is simply not running.
ensure_scp_reachable "primary PACS" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" || exit 1

# ── Ensure PACS has data ──────────────────────────────
ensure_pacs_data "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" "${TEST_DATA_DIR}"

print_header "C-FIND Query Tests"

# ── Study-Level Queries ───────────────────────────────

# Test 1: Wildcard patient query (should find >= 3 studies)
run_find_test "wildcard patient query (STUDY level)" min "${MANIFEST_STUDY_COUNT}" \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k PatientName="*" \
        -k StudyInstanceUID || true

# Test 2: Specific patient by PatientID
run_find_test "specific patient PAT001 (STUDY level)" min 1 \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k PatientID="${MANIFEST_CT_PATIENT_ID}" \
        -k StudyInstanceUID || true

# Test 3: Patient name with wildcard prefix
run_find_test "patient name DOE* (STUDY level)" min 1 \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k PatientName="${MANIFEST_CT_PATIENT_NAME%%^*}*" \
        -k StudyInstanceUID || true

# Test 4: Query by modality
run_find_test "modality filter CT (STUDY level)" min 1 \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k ModalitiesInStudy="${MANIFEST_CT_MODALITY}" \
        -k PatientName \
        -k StudyInstanceUID || true

# Test 5: Query by exact study date
run_find_test "date filter 20240115 (STUDY level)" min 1 \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyDate="${MANIFEST_CT_STUDY_DATE}" \
        -k PatientName \
        -k StudyInstanceUID || true

# Test 6: Query by date range
run_find_test "date range covering all studies (STUDY level)" min "${MANIFEST_STUDY_COUNT}" \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyDate="${MANIFEST_STUDY_DATE_RANGE}" \
        -k PatientName \
        -k StudyInstanceUID || true

# ── Series-Level Queries ──────────────────────────────

# Test 7: Series within MR study (PAT002 has 2 series: T1 + T2)
run_find_test "series in MR study PAT002 (SERIES level)" exact "${MANIFEST_MR_SERIES_COUNT}" \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=SERIES \
        -k StudyInstanceUID="${MANIFEST_MR_STUDY_UID}" \
        -k SeriesInstanceUID \
        -k Modality || true

# Test 8: Series within CT study (PAT001 has 1 series)
run_find_test "series in CT study PAT001 (SERIES level)" exact 1 \
    findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=SERIES \
        -k StudyInstanceUID="${MANIFEST_CT_STUDY_UID}" \
        -k SeriesInstanceUID \
        -k Modality || true

# ── Negative Tests ────────────────────────────────────

# Test 9: Nonexistent patient returns 0 results
TEST_TOTAL=$((TEST_TOTAL + 1))
NEG_OUTPUT=$(findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
    -S "${PACS_HOST}" "${PACS_PORT}" \
    -k QueryRetrieveLevel=STUDY \
    -k PatientID="${MANIFEST_NONEXISTENT_PATIENT_ID}" \
    -k StudyInstanceUID 2>&1 | tr -d '\0' || true)
NEG_COUNT=$(count_find_responses "${NEG_OUTPUT}")
if [ "${NEG_COUNT}" -eq 0 ]; then
    print_pass "C-FIND: nonexistent patient returns 0 results"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "C-FIND: nonexistent patient returns 0 results (got ${NEG_COUNT})"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 10: SERIES query for an unknown study returns 0 results. The
# query must also end with a final Success response, so a rejected or
# failed association cannot pass as "no matches".
TEST_TOTAL=$((TEST_TOTAL + 1))
NEG_SERIES_RC=0
NEG_SERIES_OUTPUT=$(findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
    -S "${PACS_HOST}" "${PACS_PORT}" \
    -k QueryRetrieveLevel=SERIES \
    -k StudyInstanceUID="${MANIFEST_NONEXISTENT_STUDY_UID}" \
    -k SeriesInstanceUID 2>&1 | tr -d '\0') || NEG_SERIES_RC=$?
NEG_SERIES_COUNT=$(count_find_responses "${NEG_SERIES_OUTPUT}")
NEG_SERIES_FINAL=missing
if grep -Eq '(Final Find Response|Find Response:).*\(Success\)' <<< "${NEG_SERIES_OUTPUT}"; then
    NEG_SERIES_FINAL=success
fi
if [ "${NEG_SERIES_RC}" -eq 0 ] && [ "${NEG_SERIES_FINAL}" = success ] \
        && [ "${NEG_SERIES_COUNT}" -eq 0 ]; then
    print_pass "C-FIND: unknown study returns 0 series (SERIES level)"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "C-FIND: unknown study returns 0 series (SERIES level) (exit ${NEG_SERIES_RC}, final response ${NEG_SERIES_FINAL}, found ${NEG_SERIES_COUNT})"
    if [ "${VERBOSE}" = "true" ]; then
        echo "${NEG_SERIES_OUTPUT}" | tail -10 | while IFS= read -r line; do
            print_verbose "${line}"
        done
    fi
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# ── Summary ───────────────────────────────────────────
print_summary "C-FIND"
[ "${TEST_FAILED}" -eq 0 ]
