#!/bin/bash
set -euo pipefail

# C-STORE Test
# Tests storing DICOM files to PACS servers and verifies via C-FIND.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
PACS2_HOST="${PACS2_HOST:-pacs-server-2}"
PACS2_AE="${PACS2_AE_TITLE:-DCMTK_PAC2}"
MY_AE="${AE_TITLE:-TEST_SCU}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"

# ── Ensure test data exists ───────────────────────────
if [ ! -d "${TEST_DATA_DIR}/ct" ] || [ "$(find "${TEST_DATA_DIR}" -name '*.dcm' 2>/dev/null | wc -l)" -eq 0 ]; then
    if [ -x /usr/local/bin/generate-test-data.sh ]; then
        echo "Generating test data..."
        /usr/local/bin/generate-test-data.sh "${TEST_DATA_DIR}"
    else
        echo "ERROR: No test data found and generate-test-data.sh not available"
        exit 1
    fi
fi

CT_COUNT=$(find "${TEST_DATA_DIR}/ct" -name "*.dcm" 2>/dev/null | wc -l)
MR_COUNT=$(find "${TEST_DATA_DIR}/mr" -name "*.dcm" 2>/dev/null | wc -l)
CR_COUNT=$(find "${TEST_DATA_DIR}/cr" -name "*.dcm" 2>/dev/null | wc -l)
TOTAL_FILES=$((CT_COUNT + MR_COUNT + CR_COUNT))

print_header "C-STORE Tests"
echo "  Test data: ${TOTAL_FILES} files (CT:${CT_COUNT} MR:${MR_COUNT} CR:${CR_COUNT})"
echo ""

# ── Tests ─────────────────────────────────────────────

# Test 1: Store a single CT image
SINGLE_CT=$(find "${TEST_DATA_DIR}/ct" -name "*.dcm" 2>/dev/null | head -1)
if [ -n "${SINGLE_CT}" ]; then
    run_test "single CT image to pacs-server" "C-STORE" \
        storescu -aet "${MY_AE}" -aec "${PACS_AE}" \
            "${PACS_HOST}" "${PACS_PORT}" "${SINGLE_CT}" || true
else
    print_skip "C-STORE: single CT image (no CT files found)"
fi

# Test 2: Store all CT images
run_test "all CT images (${CT_COUNT} files) to pacs-server" "C-STORE" \
    storescu -aet "${MY_AE}" -aec "${PACS_AE}" \
        +sd +r "${PACS_HOST}" "${PACS_PORT}" "${TEST_DATA_DIR}/ct/" || true

# Test 3: Store all MR images
run_test "all MR images (${MR_COUNT} files) to pacs-server" "C-STORE" \
    storescu -aet "${MY_AE}" -aec "${PACS_AE}" \
        +sd +r "${PACS_HOST}" "${PACS_PORT}" "${TEST_DATA_DIR}/mr/" || true

# Test 4: Store all CR images
run_test "all CR images (${CR_COUNT} files) to pacs-server" "C-STORE" \
    storescu -aet "${MY_AE}" -aec "${PACS_AE}" \
        +sd +r "${PACS_HOST}" "${PACS_PORT}" "${TEST_DATA_DIR}/cr/" || true

# Test 5: Store to secondary PACS
run_test "CT images to pacs-server-2 (${PACS2_AE})" "C-STORE" \
    storescu -aet "${MY_AE}" -aec "${PACS2_AE}" \
        +sd +r "${PACS2_HOST}" "${PACS_PORT}" "${TEST_DATA_DIR}/ct/" || true

# Test 6: Verify stored data via C-FIND
TEST_TOTAL=$((TEST_TOTAL + 1))
FIND_OUTPUT=$(findscu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
    -S "${PACS_HOST}" "${PACS_PORT}" \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="*" \
    -k StudyInstanceUID 2>&1 || true)

STUDY_COUNT=$(echo "${FIND_OUTPUT}" | grep -c "StudyInstanceUID" 2>/dev/null || echo "0")
if [ "${STUDY_COUNT}" -ge 3 ]; then
    print_pass "C-STORE: verification via C-FIND (found ${STUDY_COUNT} studies, expected >= 3)"
    print_verbose "Stored ${TOTAL_FILES} files across 3 patients"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "C-STORE: verification via C-FIND (found ${STUDY_COUNT} studies, expected >= 3)"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# ── Summary ───────────────────────────────────────────
print_summary "C-STORE"
[ "${TEST_FAILED}" -eq 0 ]
