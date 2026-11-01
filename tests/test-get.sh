#!/usr/bin/env bash
set -euo pipefail

# C-GET returns C-STORE sub-operations on the requesting association; it does
# not need a receiver service, listening port, or C-MOVE destination entry.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${SCRIPT_DIR}/test-helpers.sh"
# shellcheck source=tests/integrity-helpers.sh
source "${SCRIPT_DIR}/integrity-helpers.sh"
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"

print_header 'C-GET Retrieval Tests'
ensure_scp_reachable 'source PACS' "$PACS_HOST" "$PACS_PORT" "$PACS_AE" "$MY_AE" || exit 1
ensure_pacs_data "$PACS_HOST" "$PACS_PORT" "$PACS_AE" "$MY_AE" "$TEST_DATA_DIR"
WORK=$(mktemp -d /tmp/c-get-XXXXXX)
echo "C-GET evidence: ${WORK}"

get_study() {
    local study="$1" output="$2" log="$3"
    timeout 60 getscu -v -S -to 5 -ta 10 -td 20 -aet "$MY_AE" -aec "$PACS_AE" \
        -od "$output" "$PACS_HOST" "$PACS_PORT" \
        -k QueryRetrieveLevel=STUDY -k "StudyInstanceUID=$study" > "$log" 2>&1 || return 1
    grep -Eq 'Received C-GET Response \(Success\)' "$log"
}

check_count() {
    local dir="$1" expected="$2" actual
    actual=$(find "$dir" -type f | wc -l) || return 1
    [ "$actual" -eq "$expected" ] || {
        echo "Expected ${expected} received instances, got ${actual}" >&2
        return 1
    }
}

check_content() {
    local dir="$1" expected="$2" output="$3" file
    # getscu names files by SOP class/UID without a .dcm suffix. Normalize only
    # names in this fresh directory so the shared manifest reader sees them.
    find "$dir" -type f ! -name '*.dcm' -print0 > "${output}.rename" || return 1
    while IFS= read -r -d '' file; do mv "$file" "${file}.dcm" || return 1; done < "${output}.rename"
    dicom_manifest "$output" "$dir" || return 1
    diff -u "$expected" "$output"
}

for modality in ct mr cr; do
    case "$modality" in
        ct) study="$MANIFEST_CT_STUDY_UID"; count="$MANIFEST_CT_COUNT" ;;
        mr) study="$MANIFEST_MR_STUDY_UID"; count="$MANIFEST_MR_COUNT" ;;
        cr) study="$MANIFEST_CR_STUDY_UID"; count="$MANIFEST_CR_COUNT" ;;
    esac
    mkdir "${WORK}/${modality}"
    expected="${WORK}/${modality}-expected.tsv"
    dicom_manifest "$expected" "${TEST_DATA_DIR}/${modality}"
    if [ "$(wc -l < "$expected")" -ne "$count" ]; then
        print_fail "C-GET: ${modality} source fixtures disagree with the manifest count"
        exit 1
    fi
    run_test "${modality} study returns final Success" 'C-GET' get_study \
        "$study" "${WORK}/${modality}" "${WORK}/${modality}.log" || true
    run_test "${modality} study has exactly ${count} instances" 'C-GET' check_count \
        "${WORK}/${modality}" "$count" || true
    run_test "${modality} exact SOP UIDs, metadata and full PixelData" 'C-GET' check_content \
        "${WORK}/${modality}" "$expected" "${WORK}/${modality}-actual.tsv" || true
done
print_summary 'C-GET'
[ "$TEST_FAILED" -eq 0 ]
