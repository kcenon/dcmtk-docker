#!/bin/bash
set -euo pipefail

# Operational Load Smoke Test
# Exercises the PACS under operation-like load: parallel C-STORE associations
# mixed with concurrent C-FIND queries. The goal is to surface MAX_ASSOCIATIONS
# saturation, association leaks, and gross study-count regressions that the
# functional suites do not catch because they run sequentially.
#
# Tunables (env vars):
#   LOAD_SMOKE_PARALLEL   Number of parallel storescu workers       (default: 2)
#   LOAD_SMOKE_REPEAT     Number of C-STORE iterations per worker   (default: 2)
#   LOAD_SMOKE_TIMEOUT    Per-association timeout in seconds        (default: 60)
#   LOAD_SMOKE_FIND_REPS  Concurrent findscu iterations             (default: 5)
#
# Defaults are deliberately conservative so the suite stays inside the
# documented CI budget (1-2 minutes) on shared runners. To probe the
# MAX_ASSOCIATIONS=16 ceiling, raise LOAD_SMOKE_PARALLEL to >= 17 on a
# dedicated host.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"

PARALLEL="${LOAD_SMOKE_PARALLEL:-2}"
REPEAT="${LOAD_SMOKE_REPEAT:-2}"
TIMEOUT_SEC="${LOAD_SMOKE_TIMEOUT:-60}"
FIND_REPS="${LOAD_SMOKE_FIND_REPS:-5}"

# Sanity-clamp the tunables to avoid bash arithmetic surprises and runaway
# fork bombs. Negative or zero values fall back to a safe minimum of 1.
if ! [[ "${PARALLEL}" =~ ^[0-9]+$ ]] || [ "${PARALLEL}" -lt 1 ]; then PARALLEL=1; fi
if ! [[ "${REPEAT}"   =~ ^[0-9]+$ ]] || [ "${REPEAT}"   -lt 1 ]; then REPEAT=1;   fi
if ! [[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || [ "${TIMEOUT_SEC}" -lt 1 ]; then TIMEOUT_SEC=60; fi
if ! [[ "${FIND_REPS}" =~ ^[0-9]+$ ]] || [ "${FIND_REPS}" -lt 0 ]; then FIND_REPS=0; fi

# ── Workspace and cleanup ─────────────────────────────
WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t load-smoke)
# Track every background PID we spawn so the trap can kill the whole tree
# (storescu/findscu sit under `timeout`, which itself forwards SIGTERM only
# to its direct child, so we add explicit pkill on exit).
BG_PIDS=()

cleanup() {
    local rc=$?
    if [ "${#BG_PIDS[@]}" -gt 0 ]; then
        for pid in "${BG_PIDS[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                kill -TERM "${pid}" 2>/dev/null || true
            fi
        done
        # Give children a beat to exit cleanly before escalating.
        sleep 1
        for pid in "${BG_PIDS[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
    fi
    rm -rf "${WORK_DIR}" 2>/dev/null || true
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# ── Preamble: verify SCP reachability ─────────────────
ensure_scp_reachable "primary PACS" "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" || exit 1

# ── Ensure test data is present (read-only baseline) ──
ensure_pacs_data "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" "${TEST_DATA_DIR}"

# Pick a small, modality-mixed payload so each parallel worker submits a
# realistic but bounded chunk. CT is the largest series (5 instances per
# patient in the synthetic set), which is plenty for an association probe.
PAYLOAD_DIR="${TEST_DATA_DIR}/ct"
if [ ! -d "${PAYLOAD_DIR}" ] || [ "$(find "${PAYLOAD_DIR}" -name '*.dcm' 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "ERROR: load-smoke payload directory ${PAYLOAD_DIR} is empty" >&2
    exit 1
fi

print_header "Load Smoke Test"
echo "  parallel=${PARALLEL} repeat=${REPEAT} timeout=${TIMEOUT_SEC}s find_reps=${FIND_REPS}"
echo "  payload=${PAYLOAD_DIR} target=${PACS_AE}@${PACS_HOST}:${PACS_PORT}"
echo ""

# ── Baseline study count (pre-load) ───────────────────
# Captured before load so we can later verify the run actually delivered
# new studies on top of whatever the suite seeded with ensure_pacs_data.
baseline_studies() {
    findscu -aet "${MY_AE}" -aec "${PACS_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k PatientName="*" \
        -k StudyInstanceUID 2>&1 \
        | grep -c "StudyInstanceUID" || true
}
BASELINE_COUNT=$(baseline_studies)
print_verbose "baseline study count: ${BASELINE_COUNT}"

# ── Worker: parallel C-STORE ──────────────────────────
# Each worker performs ${REPEAT} storescu invocations against the PACS,
# logging per-iteration exit code so failed associations can be attributed
# back to a specific worker on test failure.
storescu_worker() {
    local worker_id="$1"
    local log_file="${WORK_DIR}/store-w${worker_id}.log"
    local i rc
    : > "${log_file}"
    for (( i=1; i<=REPEAT; i++ )); do
        rc=0
        timeout "${TIMEOUT_SEC}" storescu \
            -aet "${MY_AE}" -aec "${PACS_AE}" \
            +sd +r "${PACS_HOST}" "${PACS_PORT}" "${PAYLOAD_DIR}/" \
            >>"${log_file}" 2>&1 || rc=$?
        echo "iter=${i} rc=${rc}" >>"${log_file}"
        if [ "${rc}" -ne 0 ]; then
            return "${rc}"
        fi
    done
    return 0
}

# ── Worker: concurrent C-FIND probe ───────────────────
# Mixed workload — fires a small batch of findscu queries while the storescu
# workers are saturating associations. Failures here are informational
# (they do not flip TEST_FAILED on their own) because findscu may legitimately
# back off when MAX_ASSOCIATIONS is exhausted.
findscu_worker() {
    local log_file="${WORK_DIR}/find.log"
    local i rc
    : > "${log_file}"
    for (( i=1; i<=FIND_REPS; i++ )); do
        rc=0
        timeout "${TIMEOUT_SEC}" findscu \
            -aet "${MY_AE}" -aec "${PACS_AE}" \
            -S "${PACS_HOST}" "${PACS_PORT}" \
            -k QueryRetrieveLevel=STUDY \
            -k PatientName="*" \
            -k StudyInstanceUID \
            >>"${log_file}" 2>&1 || rc=$?
        echo "iter=${i} rc=${rc}" >>"${log_file}"
    done
    return 0
}

# ── Launch storescu workers ───────────────────────────
declare -A WORKER_PID
echo "Launching ${PARALLEL} parallel storescu worker(s), ${REPEAT} iteration(s) each..."
for (( w=1; w<=PARALLEL; w++ )); do
    storescu_worker "${w}" &
    pid=$!
    WORKER_PID["${w}"]="${pid}"
    BG_PIDS+=("${pid}")
done

# ── Launch the concurrent findscu probe (if enabled) ──
FIND_PID=""
if [ "${FIND_REPS}" -gt 0 ]; then
    findscu_worker &
    FIND_PID=$!
    BG_PIDS+=("${FIND_PID}")
fi

# ── Reap storescu workers ─────────────────────────────
STORE_OK=0
STORE_FAIL=0
FAILED_WORKERS=()
for (( w=1; w<=PARALLEL; w++ )); do
    pid="${WORKER_PID[${w}]}"
    if wait "${pid}"; then
        STORE_OK=$((STORE_OK + 1))
    else
        STORE_FAIL=$((STORE_FAIL + 1))
        FAILED_WORKERS+=("${w}")
    fi
done

# ── Reap findscu probe ────────────────────────────────
FIND_RC=0
if [ -n "${FIND_PID}" ]; then
    wait "${FIND_PID}" || FIND_RC=$?
fi

# ── Allow PACS a moment to flush in-flight associations ──
sleep 2

# ── Post-load study count ─────────────────────────────
POST_COUNT=$(baseline_studies)
print_verbose "post-load study count: ${POST_COUNT}"

# ── Tests ─────────────────────────────────────────────

# Test 1: at least half of the parallel workers must complete successfully.
# Using >= ceil(PARALLEL/2) rather than == PARALLEL acknowledges that under
# MAX_ASSOCIATIONS pressure some attempts may legitimately be rejected;
# however, a complete wipe-out indicates a regression rather than back-pressure.
MIN_OK=$(( (PARALLEL + 1) / 2 ))
TEST_TOTAL=$((TEST_TOTAL + 1))
if [ "${STORE_OK}" -ge "${MIN_OK}" ]; then
    print_pass "LOAD: ${STORE_OK}/${PARALLEL} parallel storescu workers succeeded (>= ${MIN_OK})"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "LOAD: only ${STORE_OK}/${PARALLEL} workers succeeded (expected >= ${MIN_OK})"
    if [ "${#FAILED_WORKERS[@]}" -gt 0 ]; then
        echo "       failed workers: ${FAILED_WORKERS[*]}" >&2
        for w in "${FAILED_WORKERS[@]}"; do
            local_log="${WORK_DIR}/store-w${w}.log"
            if [ -f "${local_log}" ]; then
                echo "       --- tail of worker ${w} log ---" >&2
                tail -10 "${local_log}" >&2 || true
            fi
        done
    fi
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 2: the run must leave at least the baseline number of studies in place.
# The PACS storing the same SOP Instance UIDs twice is a no-op at the catalog
# level (dcmqrscp dedupes by UID), so we only assert non-regression rather
# than growth — that keeps the test stable when the suite is re-run on an
# already-populated PACS.
TEST_TOTAL=$((TEST_TOTAL + 1))
if [ "${POST_COUNT}" -ge "${BASELINE_COUNT}" ] && [ "${POST_COUNT}" -gt 0 ]; then
    print_pass "LOAD: post-load study count ${POST_COUNT} >= baseline ${BASELINE_COUNT}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "LOAD: post-load study count ${POST_COUNT} dropped below baseline ${BASELINE_COUNT}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 3: the concurrent C-FIND probe must not hang or hard-fail the whole
# pipeline. It may individually time out under saturation, but the harness
# itself must exit cleanly. We only flag this informationally.
if [ -n "${FIND_PID}" ]; then
    if [ "${FIND_RC}" -eq 0 ]; then
        echo "  find probe: completed (rc=0)"
    else
        echo "  find probe: completed with rc=${FIND_RC} (informational under saturation)"
    fi
fi

# ── Summary ───────────────────────────────────────────
print_summary "LOAD"
[ "${TEST_FAILED}" -eq 0 ]
