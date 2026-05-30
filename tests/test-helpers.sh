#!/bin/bash
# Shared test helpers for DCMTK PACS test suite.
# Source this file from individual test scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/test-helpers.sh"

# ── TTY detection and colors ─────────────────────────
if [ -t 1 ]; then
    IS_TTY=true
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    IS_TTY=false
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_CYAN=''
    C_BOLD=''
    C_RESET=''
fi

# ── Verbose mode ──────────────────────────────────────
# Set by test-all.sh via environment; individual scripts default to off.
VERBOSE="${VERBOSE:-false}"

# ── Fixture manifest (single source of truth) ─────────
# Source the shared fixture manifest so every test script inherits the same
# OID root, UIDs, expected counts, and patient demographics that the data
# generator (scripts/generate-test-data.sh) produces. Installed to
# /usr/local/bin in the image; fall back to ../scripts for host-side runs.
# This also defines DEFAULT_OID_ROOT for back-compat.
if [ -f /usr/local/bin/fixture-manifest.sh ]; then
    # shellcheck source=scripts/fixture-manifest.sh
    source /usr/local/bin/fixture-manifest.sh
else
    _helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${_helpers_dir}/../scripts/fixture-manifest.sh" ]; then
        # shellcheck source=scripts/fixture-manifest.sh
        source "${_helpers_dir}/../scripts/fixture-manifest.sh"
    fi
fi

# ── Counters ──────────────────────────────────────────
TEST_PASSED=0
TEST_FAILED=0
TEST_TOTAL=0

# ── Output helpers ────────────────────────────────────
print_pass() {
    printf "${C_GREEN}[PASS]${C_RESET} %s\n" "$1"
}

print_fail() {
    printf "${C_RED}[FAIL]${C_RESET} %s\n" "$1"
}

print_skip() {
    printf "${C_YELLOW}[SKIP]${C_RESET} %s\n" "$1"
}

print_header() {
    printf "\n${C_BOLD}========================================${C_RESET}\n"
    printf "${C_BOLD}  %s${C_RESET}\n" "$1"
    printf "${C_BOLD}========================================${C_RESET}\n\n"
}

print_summary() {
    local label="$1"
    echo ""
    printf "%s Results: ${C_BOLD}%d/%d${C_RESET} passed" "${label}" "${TEST_PASSED}" "${TEST_TOTAL}"
    if [ "${TEST_FAILED}" -gt 0 ]; then
        printf ", ${C_RED}%d failed${C_RESET}" "${TEST_FAILED}"
    fi
    echo ""
    echo ""
}

print_verbose() {
    if [ "${VERBOSE}" = "true" ]; then
        printf "${C_CYAN}  [verbose]${C_RESET} %s\n" "$1"
    fi
}

# ── Test runner: expect command to succeed ────────────
# Usage: run_test "description" command [args...]
run_test() {
    local description="$1"
    local prefix="$2"
    shift 2
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local output=""
    local exit_code=0

    if [ "${VERBOSE}" = "true" ]; then
        output=$("$@" 2>&1) || exit_code=$?
    else
        output=$("$@" 2>&1) || exit_code=$?
    fi

    if [ "${exit_code}" -eq 0 ]; then
        print_pass "${prefix}: ${description}"
        if [ "${VERBOSE}" = "true" ] && [ -n "${output}" ]; then
            echo "${output}" | head -5 | while IFS= read -r line; do
                print_verbose "${line}"
            done
        fi
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    else
        print_fail "${prefix}: ${description}"
        if [ "${VERBOSE}" = "true" ] && [ -n "${output}" ]; then
            echo "${output}" | tail -5 | while IFS= read -r line; do
                print_verbose "${line}"
            done
        fi
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi
}

# ── Test runner: expect command to fail ───────────────
# Usage: run_test_expect_fail "description" "prefix" command [args...]
run_test_expect_fail() {
    local description="$1"
    local prefix="$2"
    shift 2
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local output=""
    output=$("$@" 2>&1) || true

    if ! "$@" >/dev/null 2>&1; then
        print_pass "${prefix}: ${description}"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    else
        print_fail "${prefix}: ${description} (expected failure but succeeded)"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi
}

# ── C-FIND response counting ──────────────────────────
# Count UID lines from a `findscu -v` capture that belong to response
# datasets (not the request key echo).
#
# Verbose findscu prints each request key once before the association,
# typically as
#   (0020,000d) UI (no value available)         #   0, 1 StudyInstanceUID
# and then prints one response dataset per match, where the same tag
# carries an actual UID value. Counting bare "StudyInstanceUID"
# occurrences therefore inflates the result by exactly one per request
# key. Filtering out lines that contain "no value available" leaves only
# response datasets.
#
# The helper also strips NUL bytes from the captured output. `findscu`
# can emit raw DICOM bytes on stderr when servers misbehave, which makes
# shell `grep` warn `ignored null byte in input` and pollutes the test
# log.
#
# Output: a single non-negative integer on stdout, nothing else.
#
# Usage: count_find_responses "<findscu -v output>" [tag1 tag2 ...]
#   When no tags are supplied the default set covers the three common
#   query-retrieve level UIDs.
count_find_responses() {
    local output="$1"
    shift
    local tags=("$@")
    if [ "${#tags[@]}" -eq 0 ]; then
        tags=(StudyInstanceUID SeriesInstanceUID SOPInstanceUID)
    fi

    local pattern
    pattern="$(IFS='|'; printf '%s' "${tags[*]}")"

    local count
    count=$(printf '%s' "${output}" \
        | tr -d '\0' \
        | grep -E "${pattern}" \
        | grep -vc "no value available" \
        || true)

    # `grep -c` with no matches exits 1; `|| true` suppresses set -e but
    # leaves count empty. Normalise to 0 so callers can use -eq / -ge.
    printf '%s' "${count:-0}"
}

# ── Verify SCP reachability via C-ECHO ────────────────
# Usage: ensure_scp_reachable "label" "host" "port" "called_ae" "calling_ae"
# Returns 0 if reachable, 1 otherwise. Prints a one-line preamble status.
ensure_scp_reachable() {
    local label="$1"
    local scp_host="$2"
    local scp_port="$3"
    local scp_ae="$4"
    local my_ae="$5"

    if echoscu -aet "${my_ae}" -aec "${scp_ae}" -to 5 \
            "${scp_host}" "${scp_port}" >/dev/null 2>&1; then
        echo "  preamble: ${label} (${scp_ae}@${scp_host}:${scp_port}) reachable"
        return 0
    fi

    echo "ERROR: preamble: ${label} (${scp_ae}@${scp_host}:${scp_port}) NOT reachable" >&2
    echo "       Verify the service is running and the AE Title is configured." >&2
    return 1
}

# ── Ensure test data is loaded into PACS ──────────────
ensure_pacs_data() {
    local pacs_host="$1"
    local pacs_port="$2"
    local pacs_ae="$3"
    local my_ae="$4"
    local data_dir="$5"

    if [ ! -d "${data_dir}" ] || [ "$(find "${data_dir}" -name '*.dcm' 2>/dev/null | wc -l)" -eq 0 ]; then
        if [ -x /usr/local/bin/generate-test-data.sh ]; then
            echo "Generating test data..."
            /usr/local/bin/generate-test-data.sh "${data_dir}"
        else
            echo "ERROR: No test data and generate-test-data.sh not available"
            return 1
        fi
    fi

    # Check if PACS already has data. Strip NUL bytes from the capture so
    # they do not trigger `ignored null byte` warnings in the test log.
    local check_output existing
    check_output=$(findscu -v -aet "${my_ae}" -aec "${pacs_ae}" \
        -S "${pacs_host}" "${pacs_port}" \
        -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID 2>&1 \
        | tr -d '\0' || true)
    existing=$(count_find_responses "${check_output}" StudyInstanceUID)

    if [ "${existing}" -lt "${MANIFEST_STUDY_COUNT}" ]; then
        echo "Loading test data into PACS..."
        storescu -aet "${my_ae}" -aec "${pacs_ae}" \
            +sd +r "${pacs_host}" "${pacs_port}" "${data_dir}/" >/dev/null 2>&1 || true
        sleep 1
    fi
}

# ── Verify PACS is empty (cleanup must happen on the host) ────
# Verification-only helper. Destructive cleanup of PACS storage must be
# performed on the host by the caller (e.g. `pacs.sh` or the CI workflow)
# before this script runs inside the test-client container.
#
# Rationale: the test-client image does not include the Docker CLI, and
# its own `/dicom/db` is not the PACS server's storage volume. Any in-
# container attempt to delete `/dicom/db` would target the wrong path and
# silently leave PACS data intact. See issue #19.
#
# Behavior:
#   1. Probes the SCP with C-ECHO; returns non-zero if unreachable.
#   2. Queries the SCP for any remaining studies via C-FIND.
#   3. Returns non-zero (and logs ERROR) if any studies remain. This makes
#      the test fail loudly rather than continuing against dirty state.
#
# Usage:
#   ensure_clean_pacs "host" "port" "called_ae" "calling_ae"
ensure_clean_pacs() {
    local pacs_host="$1"
    local pacs_port="$2"
    local pacs_ae="$3"
    local my_ae="$4"

    # Verify the SCP responds before querying study count
    if ! echoscu -aet "${my_ae}" -aec "${pacs_ae}" -to 5 \
            "${pacs_host}" "${pacs_port}" >/dev/null 2>&1; then
        echo "ERROR: ensure_clean_pacs: ${pacs_ae}@${pacs_host}:${pacs_port} not reachable" >&2
        return 1
    fi

    # Query for any remaining studies; the host-side caller is responsible
    # for wiping PACS storage before this helper runs. Strip NUL bytes from
    # the capture so they do not trigger `ignored null byte` warnings.
    local check_output remaining
    check_output=$(findscu -v -aet "${my_ae}" -aec "${pacs_ae}" \
        -S "${pacs_host}" "${pacs_port}" \
        -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID 2>&1 \
        | tr -d '\0' || true)
    remaining=$(count_find_responses "${check_output}" StudyInstanceUID)

    if [ "${remaining}" -gt 0 ]; then
        echo "ERROR: ensure_clean_pacs: ${remaining} studies remain on ${pacs_ae}@${pacs_host}:${pacs_port}" >&2
        echo "       The host-side runner must wipe PACS storage before invoking this test." >&2
        return 1
    fi

    echo "  ensure_clean_pacs: ${pacs_ae}@${pacs_host}:${pacs_port} is empty"
    return 0
}

# ── C-MOVE receiver verification helpers ──────────────────────
# These helpers let C-MOVE tests verify that the requested instances
# actually arrived at the storescp-receiver destination, instead of
# trusting movescu's exit code alone. They depend on the receiver
# storage volume (`received-data`) being mounted into test-client at
# ${STORESCP_STORAGE_DIR} (default /dicom/received); see issue #33.
#
# Layout: storescp runs with `--sort-on-study-uid prefix`, which
# produces `<prefix><StudyInstanceUID>/<file>.dcm` under the storage
# directory. The helpers below use `find` + DICOM tags from dcmdump
# rather than assuming a specific directory layout, so they stay
# robust if the sorting strategy changes.

# Resolve the receiver storage directory (env override → default).
receiver_storage_dir() {
    echo "${STORESCP_STORAGE_DIR:-/dicom/received}"
}

# Remove every previously-received instance under the receiver storage
# directory. Non-destructive on the directory itself so storescp can
# keep writing new files into it without restarting.
#
# Usage: receiver_cleanup_storage [storage_dir]
receiver_cleanup_storage() {
    local storage_dir="${1:-$(receiver_storage_dir)}"

    if [ ! -d "${storage_dir}" ]; then
        echo "ERROR: receiver_cleanup_storage: ${storage_dir} not mounted in test-client" >&2
        echo "       Ensure docker-compose.yml mounts received-data into test-client." >&2
        return 1
    fi

    # Delete every regular file and empty sub-directory below storage_dir,
    # but keep storage_dir itself so storescp can continue writing.
    find "${storage_dir}" -mindepth 1 -delete 2>/dev/null || true
    print_verbose "receiver_cleanup_storage: wiped ${storage_dir}"
    return 0
}

# Count .dcm files under the receiver storage directory.
#
# Usage: receiver_dcm_count [storage_dir]
# Prints the file count on stdout.
receiver_dcm_count() {
    local storage_dir="${1:-$(receiver_storage_dir)}"

    if [ ! -d "${storage_dir}" ]; then
        echo "0"
        return 1
    fi

    find "${storage_dir}" -type f -name '*.dcm' 2>/dev/null | wc -l | tr -d ' '
}

# Dump receiver storage contents on failure to aid debugging.
#
# Usage: receiver_dump_storage [storage_dir]
receiver_dump_storage() {
    local storage_dir="${1:-$(receiver_storage_dir)}"

    echo "       Receiver storage (${storage_dir}):"
    if [ -d "${storage_dir}" ]; then
        find "${storage_dir}" -type f -name '*.dcm' 2>/dev/null \
            | head -20 \
            | sed 's/^/         /' \
            || true
    else
        echo "         (not mounted)"
    fi
}

# Verify that exactly `expected` .dcm files exist under the receiver
# storage directory. Increments TEST_TOTAL and TEST_PASSED/FAILED so
# the C-MOVE suite picks up the result via print_summary.
#
# Usage: verify_move_count "<test label>" <expected> [storage_dir]
verify_move_count() {
    local label="$1"
    local expected="$2"
    local storage_dir="${3:-$(receiver_storage_dir)}"

    TEST_TOTAL=$((TEST_TOTAL + 1))
    local actual
    actual=$(receiver_dcm_count "${storage_dir}")

    if [ "${actual}" = "${expected}" ]; then
        print_pass "C-MOVE: ${label} (received ${actual}/${expected} instances)"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "C-MOVE: ${label} (received ${actual} instances, expected ${expected})"
    receiver_dump_storage "${storage_dir}"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# Verify that every .dcm file under the receiver storage directory
# carries the expected StudyInstanceUID and, when provided, the
# expected SeriesInstanceUID. Uses dcmdump's +P selector to read
# specific tags without parsing the full dataset.
#
# Usage: verify_move_uids "<test label>" <study_uid> [series_uid] [storage_dir]
verify_move_uids() {
    local label="$1"
    local study_uid="$2"
    local series_uid="${3:-}"
    local storage_dir="${4:-$(receiver_storage_dir)}"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    if ! command -v dcmdump >/dev/null 2>&1; then
        print_fail "C-MOVE: ${label} (dcmdump not available)"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi

    local files file extracted mismatched_study=0 mismatched_series=0 missing_sop=0 scanned=0
    files=$(find "${storage_dir}" -type f -name '*.dcm' 2>/dev/null)

    if [ -z "${files}" ]; then
        print_fail "C-MOVE: ${label} (no instances to inspect under ${storage_dir})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi

    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        scanned=$((scanned + 1))

        extracted=$(dcmdump +P StudyInstanceUID "${file}" 2>/dev/null \
            | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -1)
        if [ "${extracted}" != "${study_uid}" ]; then
            mismatched_study=$((mismatched_study + 1))
            print_verbose "verify_move_uids: study mismatch in ${file} (got '${extracted}', expected '${study_uid}')"
        fi

        if [ -n "${series_uid}" ]; then
            extracted=$(dcmdump +P SeriesInstanceUID "${file}" 2>/dev/null \
                | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -1)
            if [ "${extracted}" != "${series_uid}" ]; then
                mismatched_series=$((mismatched_series + 1))
                print_verbose "verify_move_uids: series mismatch in ${file} (got '${extracted}', expected '${series_uid}')"
            fi
        fi

        extracted=$(dcmdump +P SOPInstanceUID "${file}" 2>/dev/null \
            | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -1)
        if [ -z "${extracted}" ]; then
            missing_sop=$((missing_sop + 1))
        fi
    done <<EOF
${files}
EOF

    if [ "${mismatched_study}" -eq 0 ] && [ "${mismatched_series}" -eq 0 ] && [ "${missing_sop}" -eq 0 ]; then
        print_pass "C-MOVE: ${label} (${scanned} instances match expected UIDs)"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "C-MOVE: ${label} (scanned=${scanned} study-mismatch=${mismatched_study} series-mismatch=${mismatched_series} missing-sop=${missing_sop})"
    receiver_dump_storage "${storage_dir}"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}
