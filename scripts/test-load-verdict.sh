#!/usr/bin/env bash
set -euo pipefail
# Host-side negative regressions. Run only against an isolated synthetic
# Compose stack. Uses its existing COMPOSE_FILE/COMPOSE_PROJECT_NAME settings.

WORK=$(mktemp -d -t load-verdict-XXXXXX)
PROBE=""
MISSING_PATH=""
cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "${MISSING_PATH}" ]; then
        docker compose exec -T pacs-server mv /tmp/load-verdict-missing.dcm "${MISSING_PATH}" || rc=1
    fi
    if [ -n "${PROBE}" ]; then
        docker compose exec -T test-client rm -rf "${PROBE}" || rc=1
    fi
    if [ "${rc}" -eq 0 ]; then rm -rf "${WORK}"; else echo "Verdict logs retained: ${WORK}" >&2; fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

smoke() {
    docker compose exec -T -e LOAD_SMOKE_PARALLEL=1 -e LOAD_SMOKE_REPEAT=1 \
        -e LOAD_SMOKE_FIND_REPS=1 -e LOAD_SMOKE_TIMEOUT=30 "$@" \
        test-client bash /tests/test-load-smoke.sh
}
expect_failure() {
    local name="$1" marker="$2" rc=0
    shift 2
    smoke "$@" > "${WORK}/${name}.log" 2>&1 || rc=$?
    if [ "${rc}" -eq 0 ] || ! grep -Fq "${marker}" "${WORK}/${name}.log"; then
        cat "${WORK}/${name}.log" >&2
        echo "ERROR: ${name} did not fail for the intended reason (rc=${rc})" >&2
        return 1
    fi
    echo "PASS: ${name} is rejected (rc=${rc})"
}

# Establish a healthy baseline and real stored MR files, using one writer.
smoke > "${WORK}/baseline.log" 2>&1 || { cat "${WORK}/baseline.log"; exit 1; }
MISSING_PATH=$(docker compose exec -T pacs-server sh -c \
    'find "/dicom/db/$AE_TITLE" -type f -name "MR_*.dcm" -print -quit')
[ -n "${MISSING_PATH}" ] || { echo 'ERROR: no stored MR file for fault injection'; exit 1; }
docker compose exec -T pacs-server mv "${MISSING_PATH}" /tmp/load-verdict-missing.dcm
expect_failure missing-file '[FAIL] LOAD: pre-load UIDs, retrieval, metadata and PixelData'
if grep -q '^Launching ' "${WORK}/missing-file.log"; then
    echo 'ERROR: missing file was not rejected before the workload'; exit 1
fi
docker compose exec -T pacs-server mv /tmp/load-verdict-missing.dcm "${MISSING_PATH}"
MISSING_PATH=""

# Shadow just the client under test. Other operations use real DCMTK tools.
PROBE=$(docker compose exec -T test-client mktemp -d /tmp/load-verdict-bin-XXXXXX)
docker compose exec -T test-client sh -c 'cat > "$1/storescu"; chmod +x "$1/storescu"' sh "${PROBE}" <<'STORE'
#!/bin/sh
echo 'Injected storescu failure' >&2
exit 42
STORE
expect_failure store-worker '[FAIL] LOAD: all 1 store workers succeed (0/1)' \
    -e "PATH=${PROBE}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
grep -Fq '[PASS] LOAD: post-load UIDs, retrieval, metadata and PixelData' "${WORK}/store-worker.log"
docker compose exec -T test-client rm "${PROBE}/storescu"
docker compose exec -T test-client sh -c 'cat > "$1/findscu"; chmod +x "$1/findscu"' sh "${PROBE}" <<'FIND'
#!/bin/sh
for arg do
    if [ "$arg" = QueryRetrieveLevel=STUDY ]; then
        echo 'Injected concurrent findscu failure' >&2
        exit 42
    fi
done
exec /usr/bin/findscu "$@"
FIND
expect_failure query-worker '[FAIL] LOAD: all 1 concurrent queries succeed' \
    -e "PATH=${PROBE}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
grep -Fq '[PASS] LOAD: post-load UIDs, retrieval, metadata and PixelData' "${WORK}/query-worker.log"
docker compose exec -T test-client rm -rf "${PROBE}"
PROBE=""
smoke > "${WORK}/restored.log" 2>&1 || { cat "${WORK}/restored.log"; exit 1; }
echo 'PASS: restored stack passes UID and full PixelData verification'
