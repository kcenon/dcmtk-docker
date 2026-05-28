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

# ── Canonical OID root ────────────────────────────────
# Single source of truth for the test-data OID root. Must match
# scripts/generate-test-data.sh and env.default so standalone test
# scripts query the same UIDs that the generator produces.
DEFAULT_OID_ROOT="1.2.826.0.1.3680043.8.499"

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

    # Check if PACS already has data
    local check_output existing
    check_output=$(findscu -aet "${my_ae}" -aec "${pacs_ae}" \
        -S "${pacs_host}" "${pacs_port}" \
        -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID 2>&1 || true)
    existing=$(echo "${check_output}" | grep -c "StudyInstanceUID" 2>/dev/null || echo "0")

    if [ "${existing}" -lt 3 ]; then
        echo "Loading test data into PACS..."
        storescu -aet "${my_ae}" -aec "${pacs_ae}" \
            +sd +r "${pacs_host}" "${pacs_port}" "${data_dir}/" >/dev/null 2>&1 || true
        sleep 1
    fi
}

# ── Wipe PACS storage and reload from scratch ─────────
# Canonical bootstrap helper for tests that require a clean PACS.
# Idempotent: safe to call multiple times. Always leaves the PACS empty
# of test data after the wipe (callers typically follow with storescu).
#
# The container hosting dcmqrscp is identified by ${pacs_host} which, in
# the docker-compose setup, doubles as the compose service name. Storage
# is wiped via `docker compose exec` against that service's STORAGE_DIR,
# which scopes naturally to the active compose project so parallel
# stacks do not collide.
#
# Usage:
#   ensure_clean_pacs "host" "port" "called_ae" "calling_ae" [service] [storage_dir]
#
# Defaults:
#   service     -> ${pacs_host}
#   storage_dir -> /dicom/db (matches docker-compose pacs-server config)
ensure_clean_pacs() {
    local pacs_host="$1"
    local pacs_port="$2"
    local pacs_ae="$3"
    local my_ae="$4"
    local service="${5:-${pacs_host}}"
    local storage_dir="${6:-/dicom/db}"

    # Verify the SCP responds before attempting destructive work
    if ! echoscu -aet "${my_ae}" -aec "${pacs_ae}" -to 5 \
            "${pacs_host}" "${pacs_port}" >/dev/null 2>&1; then
        echo "ERROR: ensure_clean_pacs: ${pacs_ae}@${pacs_host}:${pacs_port} not reachable" >&2
        return 1
    fi

    # Detect docker compose binary (v2 plugin preferred, legacy fallback)
    local dc=""
    if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            dc="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            dc="docker-compose"
        fi
    fi

    # Resolve the compose service to a container ID under the current
    # compose project, so we never assume a fixed container_name.
    local container_id=""
    if [ -n "${dc}" ]; then
        container_id=$(${dc} ps -q "${service}" 2>/dev/null | head -n1)
    fi

    # Wipe the PACS storage directory inside the container.
    # Two strategies, in order of preference:
    #   1. docker compose exec/restart (when running on the host with docker compose)
    #   2. direct rm                   (when this helper is itself running inside the PACS container)
    if [ -n "${dc}" ] && [ -n "${container_id}" ]; then
        echo "Wiping PACS storage in service ${service}:${storage_dir}"
        ${dc} exec -T "${service}" sh -c \
            "find '${storage_dir}' -mindepth 1 -delete 2>/dev/null || true"
        # Restart dcmqrscp so the index is re-read from the now-empty dir
        ${dc} restart "${service}" >/dev/null 2>&1 || true
        # Wait for the container to come back online
        local i
        for i in $(seq 1 30); do
            if echoscu -aet "${my_ae}" -aec "${pacs_ae}" -to 2 \
                    "${pacs_host}" "${pacs_port}" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    elif [ -d "${storage_dir}" ] && [ -w "${storage_dir}" ]; then
        echo "Wiping PACS storage at ${storage_dir} (in-container mode)"
        find "${storage_dir}" -mindepth 1 -delete 2>/dev/null || true
    else
        echo "WARNING: ensure_clean_pacs: no docker compose access and ${storage_dir} not writable" >&2
        echo "         PACS will not be wiped; tests may observe pre-existing data." >&2
        return 0
    fi

    # Verify the wipe succeeded by re-querying study count
    local check_output remaining
    check_output=$(findscu -aet "${my_ae}" -aec "${pacs_ae}" \
        -S "${pacs_host}" "${pacs_port}" \
        -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID 2>&1 || true)
    remaining=$(echo "${check_output}" | grep -c "StudyInstanceUID" 2>/dev/null || echo "0")

    if [ "${remaining}" -gt 0 ]; then
        echo "WARNING: ensure_clean_pacs: ${remaining} studies remain after wipe" >&2
    else
        echo "  ensure_clean_pacs: PACS storage cleared"
    fi
    return 0
}
