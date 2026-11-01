#!/bin/bash
set -euo pipefail

# Normal-load integrity test. Every operation must succeed. Saturation is a
# separate experiment; this suite never accepts an arbitrary failure fraction.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"
source "${SCRIPT_DIR}/integrity-helpers.sh"

PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
PARALLEL="${LOAD_SMOKE_PARALLEL:-2}"
REPEAT="${LOAD_SMOKE_REPEAT:-2}"
TIMEOUT_SEC="${LOAD_SMOKE_TIMEOUT:-60}"
FIND_REPS="${LOAD_SMOKE_FIND_REPS:-5}"

# Reject malformed input instead of silently running a different workload.
for key in PARALLEL REPEAT TIMEOUT_SEC FIND_REPS; do
    value="${!key}"
    if ! [[ "${value}" =~ ^(0|[1-9][0-9]{0,5})$ ]] || { [ "${key}" != FIND_REPS ] && [ "${value}" -eq 0 ]; }; then
        echo "ERROR: invalid ${key}=${value}" >&2
        exit 1
    fi
done

WORK_DIR=$(mktemp -d -t load-smoke-XXXXXX)
BG_PIDS=()
# Separate process groups let cancellation reach timeout and its DCMTK client.
set -m
cleanup() {
    local rc=$? pid
    trap - EXIT
    for pid in "${BG_PIDS[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    if [ "${rc}" -ne 0 ]; then
        echo "LOAD diagnostics retained in ${WORK_DIR}" >&2
        find "${WORK_DIR}" -name '*.log' -type f -exec sh -c '
            for f do echo "--- $f"; tail -20 "$f"; done
        ' sh {} + >&2
    else
        rm -rf "${WORK_DIR}"
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_header "Load Smoke Test"
echo "  parallel=${PARALLEL} repeat=${REPEAT} timeout=${TIMEOUT_SEC}s find_reps=${FIND_REPS}"
echo "  mode=normal target=${PACS_AE}@${PACS_HOST}:${PACS_PORT}"
ensure_scp_reachable "primary PACS" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" || exit 1
ensure_scp_reachable "receiver" "${STORESCP_HOST:-storescp-receiver}" "${STORESCP_PORT:-${PACS_PORT}}" \
    "${STORESCP_AE_TITLE:-STORE_SCP}" "${MY_AE}" || exit 1

# Freeze source modalities, excluding derived artifacts under data/. An
# already-missing MR must not become an accepted baseline or be reseeded away.
mkdir "${WORK_DIR}/fixtures"
for modality in ct mr cr; do
    cp -R "${TEST_DATA_DIR}/${modality}" "${WORK_DIR}/fixtures/"
done
EXPECTED="${WORK_DIR}/expected.tsv"
dicom_manifest "${EXPECTED}" "${WORK_DIR}/fixtures" || exit 1
[ "$(wc -l < "${EXPECTED}")" -eq "${MANIFEST_TOTAL_COUNT}" ] || {
    echo "ERROR: expected ${MANIFEST_TOTAL_COUNT} unique source instances" >&2; exit 1;
}
query_instance_uids "${EXPECTED}" "${WORK_DIR}/initial-uids" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" || exit 1
if [ ! -s "${WORK_DIR}/initial-uids" ]; then
    mapfile -d '' files < <(find "${WORK_DIR}/fixtures" -name '*.dcm' -print0)
    timeout "${TIMEOUT_SEC}" storescu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
        "${PACS_HOST}" "${PACS_PORT}" "${files[@]}" > "${WORK_DIR}/seed.log" 2>&1
fi
run_test "pre-load UIDs, retrieval, metadata and PixelData" "LOAD" \
    verify_instance_integrity "${EXPECTED}" "${WORK_DIR}/before" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" || exit 1

storescu_worker() {
    local worker="$1" i rc failed=0
    for ((i=1; i<=REPEAT; i++)); do
        rc=0
        timeout "${TIMEOUT_SEC}" storescu -v -aet "${MY_AE}" -aec "${PACS_AE}" \
            +sd +r "${PACS_HOST}" "${PACS_PORT}" "${WORK_DIR}/fixtures/" \
            >> "${WORK_DIR}/store-${worker}.log" 2>&1 || rc=$?
        echo "iter=${i} rc=${rc}" >> "${WORK_DIR}/store-${worker}.log"
        [ "${rc}" -eq 0 ] || failed=1
    done
    return "${failed}"
}

findscu_worker() {
    local i rc failed=0 log
    for ((i=1; i<=FIND_REPS; i++)); do
        rc=0
        log="${WORK_DIR}/find-${i}.log"
        timeout "${TIMEOUT_SEC}" findscu -v -S -aet "${MY_AE}" -aec "${PACS_AE}" \
            "${PACS_HOST}" "${PACS_PORT}" -k QueryRetrieveLevel=STUDY \
            -k StudyInstanceUID > "${log}" 2>&1 || rc=$?
        if [ "${rc}" -eq 0 ] && ! grep -aqE '(Final Find Response|Find Response:).*\(Success\)' "${log}"; then rc=1; fi
        echo "iter=${i} rc=${rc}" >> "${log}"
        [ "${rc}" -eq 0 ] || failed=1
    done
    return "${failed}"
}

echo "Launching ${PARALLEL} parallel storescu worker(s), ${REPEAT} iteration(s) each..."
for ((w=1; w<=PARALLEL; w++)); do
    storescu_worker "${w}" &
    BG_PIDS+=("$!")
done
FIND_PID=""
if [ "${FIND_REPS}" -gt 0 ]; then
    findscu_worker &
    FIND_PID=$!
    BG_PIDS+=("${FIND_PID}")
fi

STORE_OK=0
for ((w=0; w<PARALLEL; w++)); do
    if wait "${BG_PIDS[${w}]}"; then STORE_OK=$((STORE_OK + 1)); fi
done
FIND_RC=0
if [ -n "${FIND_PID}" ]; then wait "${FIND_PID}" || FIND_RC=$?; fi
BG_PIDS=()

run_test "all ${PARALLEL} store workers succeed (${STORE_OK}/${PARALLEL})" "LOAD" \
    test "${STORE_OK}" -eq "${PARALLEL}" || true
if [ -n "${FIND_PID}" ]; then
    run_test "all ${FIND_REPS} concurrent queries succeed" "LOAD" test "${FIND_RC}" -eq 0 || true
fi
# Still inspect integrity after operation errors to retain useful evidence.
run_test "post-load UIDs, retrieval, metadata and PixelData" "LOAD" \
    verify_instance_integrity "${EXPECTED}" "${WORK_DIR}/after" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" || true
print_summary "LOAD"
[ "${TEST_FAILED}" -eq 0 ]
