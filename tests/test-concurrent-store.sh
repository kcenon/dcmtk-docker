#!/bin/bash
set -euo pipefail
# Run in an isolated project. Repeated and disjoint UIDs use the same studies,
# so each phase can compare the entire query/disk/retrieval manifest exactly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"
source "${SCRIPT_DIR}/integrity-helpers.sh"
MY_AE="${AE_TITLE:-TEST_SCU}"
TIMEOUT_SEC=60
HOSTS=("${PACS_HOST:-pacs-server}" "${PACS2_HOST:-pacs-server-2}")
AES=("${PACS_AE_TITLE:-DCMTK_PACS}" "${PACS2_AE_TITLE:-DCMTK_PAC2}")
PORTS=("${PACS_PORT:-11112}" "${PACS2_PORT:-${PACS_PORT:-11112}}")
DISKS=(/dicom/primary-db /dicom/secondary-db)
PIDS=()
set -m

verify_target() {
    local expected="$1" label="$2" server="$3"
    local prefix="${WORK}/${label}-${server}"
    verify_instance_integrity "${expected}" "${prefix}" "${HOSTS[${server}]}" \
        "${PORTS[${server}]}" "${AES[${server}]}" || return 1
    dicom_manifest "${prefix}.disk" "${DISKS[${server}]}" || return 1
    diff -u "${expected}" "${prefix}.disk"
}

if [ "${1:-}" = --verify-only ] && [ "$#" -eq 2 ]; then
    WORK="$2"
    [ -s "${WORK}/disjoint.tsv" ] || exit 1
    for server in 0 1; do
        run_test "recovered ${AES[${server}]} query/disk/retrieval integrity" "CONCURRENT" \
            verify_target "${WORK}/disjoint.tsv" recovered "${server}" || true
    done
    print_summary "CONCURRENT recovery"
    [ "${TEST_FAILED}" -eq 0 ]
    exit
elif [ "$#" -ne 0 ]; then
    echo 'Usage: test-concurrent-store.sh [--verify-only workspace]' >&2
    exit 2
fi

WORK=$(mktemp -d -t concurrent-store-XXXXXX)
cleanup() {
    local rc=$? pid
    trap - EXIT
    for pid in "${PIDS[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    echo "Concurrent storage workspace: ${WORK}"
    if [ "${rc}" -ne 0 ]; then
        find "${WORK}" -name '*.log' -exec sh -c 'for f do echo "--- $f"; tail -12 "$f"; done' sh {} + >&2
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "${WORK}/fixtures"
for modality in ct mr cr; do cp -R "${TEST_DATA_DIR:-/dicom/testdata}/${modality}" "${WORK}/fixtures/"; done
dicom_manifest "${WORK}/same.tsv" "${WORK}/fixtures"
[ "$(wc -l < "${WORK}/same.tsv")" -eq "${MANIFEST_TOTAL_COUNT}" ]
mapfile -d '' FILES < <(find "${WORK}/fixtures" -name '*.dcm' -print0 | sort -z)
for server in 0 1; do
    ensure_scp_reachable "PACS" "${HOSTS[${server}]}" "${PORTS[${server}]}" "${AES[${server}]}" "${MY_AE}"
    timeout "${TIMEOUT_SEC}" storescu -v -aet "${MY_AE}" -aec "${AES[${server}]}" \
        "${HOSTS[${server}]}" "${PORTS[${server}]}" "${FILES[@]}" > "${WORK}/seed-${server}.log" 2>&1
    verify_target "${WORK}/same.tsv" seeded "${server}"
done

store_worker() {
    local phase="$1" server="$2" worker="$3" directory="$4" i rc failed=0
    for ((i=1; i<=10; i++)); do
        rc=0
        timeout "${TIMEOUT_SEC}" storescu -v -aet "${MY_AE}" -aec "${AES[${server}]}" \
            +sd +r "${HOSTS[${server}]}" "${PORTS[${server}]}" "${directory}/" \
            >> "${WORK}/${phase}-store-${server}-${worker}.log" 2>&1 || rc=$?
        echo "iteration=${i} rc=${rc}" >> "${WORK}/${phase}-store-${server}-${worker}.log"
        [ "${rc}" -eq 0 ] || failed=1
    done
    return "${failed}"
}
query_worker() {
    local phase="$1" server="$2" i failed=0
    for ((i=1; i<=5; i++)); do
        query_instance_uids "${WORK}/same.tsv" "${WORK}/${phase}-probe-${server}-${i}" \
            "${HOSTS[${server}]}" "${PORTS[${server}]}" "${AES[${server}]}" || failed=1
    done
    return "${failed}"
}
run_phase() {
    local phase="$1" server worker directory pid failed=0
    PIDS=()
    for server in 0 1; do
        for worker in 1 2 3 4; do
            directory="${WORK}/fixtures"
            [ "${phase}" = same ] || directory="${WORK}/worker-${worker}"
            store_worker "${phase}" "${server}" "${worker}" "${directory}" &
            PIDS+=("$!")
        done
        query_worker "${phase}" "${server}" &
        PIDS+=("$!")
    done
    for pid in "${PIDS[@]}"; do wait "${pid}" || failed=1; done
    PIDS=()
    run_test "${phase}: all 80 store associations and concurrent queries succeed" "CONCURRENT" \
        test "${failed}" -eq 0 || true
    for server in 0 1; do
        run_test "${phase}: ${AES[${server}]} exact query/disk/retrieval integrity" "CONCURRENT" \
            verify_target "${WORK}/${phase}.tsv" "${phase}" "${server}" || true
    done
}

print_header "Concurrent Storage Integrity"
run_phase same
# Each worker owns a disjoint immutable set; the original 13 remain indexed.
cp "${WORK}/same.tsv" "${WORK}/disjoint.tsv"
for worker in 1 2 3 4; do
    mkdir "${WORK}/worker-${worker}"
    n=0
    for file in "${FILES[@]}"; do
        n=$((n + 1))
        destination="${WORK}/worker-${worker}/${n}.dcm"
        cp "${file}" "${destination}"
        dcmodify -nb -i "(0008,0018)=${MANIFEST_OID_ROOT}.91.${worker}.${n}" "${destination}"
    done
    dicom_manifest "${WORK}/worker-${worker}.tsv" "${WORK}/worker-${worker}"
    cat "${WORK}/worker-${worker}.tsv" >> "${WORK}/disjoint.tsv"
done
LC_ALL=C sort -o "${WORK}/disjoint.tsv" "${WORK}/disjoint.tsv"
run_phase disjoint
print_summary "CONCURRENT"
[ "${TEST_FAILED}" -eq 0 ]
